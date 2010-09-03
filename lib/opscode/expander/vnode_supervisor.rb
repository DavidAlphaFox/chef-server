require 'yajl'
require 'eventmachine'
require 'amqp'
require 'mq'
require 'opscode/expander/version'
require 'opscode/expander/loggable'
require 'opscode/expander/node'
require 'opscode/expander/vnode'
require 'opscode/expander/vnode_table'
require 'opscode/expander/configuration'

module Opscode
  module Expander
    class VNodeSupervisor
      include Loggable
      extend  Loggable

      def self.start
        @vnode_supervisor = new
        Kernel.trap(:INT)  { stop(:INT) }
        Kernel.trap(:TERM) { stop(:TERM) }

        Expander.init_config(ARGV)

        log.info("Opscode Expander #{VERSION} starting up.")

        AMQP.start(Expander.config.amqp_config) do
          log.debug { "Setting prefetch count to 5"}
          MQ.prefetch(5)

          vnodes = Expander.config.vnode_numbers
          log.info("Starting Consumers for vnodes #{vnodes.min}-#{vnodes.max}")
          @vnode_supervisor.start(vnodes)
        end
        
      end

      def self.stop(signal)
        log.info { "Stopping opscode-expander on signal (#{signal})" }
        @vnode_supervisor.stop
        EM.add_timer(3) do
          AMQP.stop
          EM.stop
        end
      end

      attr_reader :vnode_table

      attr_reader :local_node

      def initialize
        @vnodes = {}
        @vnode_table = VNodeTable.new(self)
        @local_node  = Node.local_node
        @queue_name, @guid = nil, nil
      end

      def start(vnode_ids)
        @local_node.start do |message|
          process_control_message(message)
        end

        #start_vnode_table_publisher

        Array(vnode_ids).each { |vnode_id| spawn_vnode(vnode_id) }
      end

      def stop
        @local_node.stop

        #log.debug { "stopping vnode table updater" }
        #@vnode_table_publisher.cancel

        log.info { "Stopping VNode queue subscribers"}
        @vnodes.each do |vnode_number, vnode|
          log.debug { "Stopping consumer on VNode #{vnode_number}"}
          vnode.stop
        end
        
      end

      def vnode_added(vnode)
        log.debug { "vnode #{vnode.vnode_number} registered with supervisor" }
        @vnodes[vnode.vnode_number.to_i] = vnode
      end

      def vnode_removed(vnode)
        log.debug { "vnode #{vnode.vnode_number} unregistered from supervisor" }
        @vnodes.delete(vnode.vnode_number.to_i)
      end

      def vnodes
        @vnodes.keys.sort
      end

      def spawn_vnode(vnode_number)
        VNode.new(vnode_number, self).start
      end

      def release_vnode
        # TODO
      end

      def process_control_message(message)
        control_message = parse_symbolic(message)
        case control_message[:action]
        when "claim_vnode"
          spawn_vnode(control_message[:vnode_id])
        when "recover_vnode"
          recover_vnode(control_message[:vnode_id])
        when "release_vnodes"
          raise "todo"
          release_vnode()
        when "update_vnode_table"
          @vnode_table.update_table(control_message[:data])
        when "vnode_table_publish"
          publish_vnode_table
        when "status"
          publish_status_to(control_message[:rsvp])
        when "set_log_level"
          set_log_level(control_message[:level], control_message[:rsvp])
        else
          log.error { "invalid control message #{control_message.inspect}" }
        end
      rescue Exception => e
        log.error { "Error processing a control message."}
        log.error { "#{e.class.name}: #{e.message}\n#{e.backtrace.join("\n")}" }
      end


      def start_vnode_table_publisher
        @vnode_table_publisher = EM.add_periodic_timer(10) { publish_vnode_table }
      end

      def publish_vnode_table
        status_update = @local_node.to_hash
        status_update[:vnodes] = vnodes
        status_update[:update] = :add
        @local_node.broadcast_message(Yajl::Encoder.encode({:action => :update_vnode_table, :data => status_update}))
      end

      def publish_status_to(return_queue)
        status_update = @local_node.to_hash
        status_update[:vnodes] = vnodes
        MQ.queue(return_queue).publish(Yajl::Encoder.encode(status_update))
      end

      def set_log_level(level, rsvp_to)
        log.info { "setting log level to #{level} due to command from #{rsvp_to}" }
        new_log_level = (Expander.config.log_level = level.to_sym)
        reply = {:level => new_log_level, :node => @local_node.to_hash}
        MQ.queue(rsvp_to).publish(Yajl::Encoder.encode(reply))
      end

      def recover_vnode(vnode_id)
        if @vnode_table.local_node_is_leader?
          log.debug { "Recovering vnode: #{vnode_id}" }
          @local_node.shared_message(Yajl::Encoder.encode({:action => :claim_vnode, :vnode_id => vnode_id}))
        else
          log.debug { "Ignoring :recover_vnode message because this node is not the leader" }
        end
      end

      def parse_symbolic(message)
        Yajl::Parser.new(:symbolize_keys => true).parse(message)
      end

    end
  end
end