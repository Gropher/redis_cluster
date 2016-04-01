module RedisCluster

  class Client

    def initialize(startup_hosts, global_configs)
      @startup_hosts = startup_hosts
      @pool = Pool.new
      @locking = false
      reload_pool_nodes
    end

    def execute(method, args)
      ttl = Configuration::REQUEST_TTL
      asking = false
      try_random_node = false

      while ttl > 0
        ttl -= 1
        begin
          return @pool.execute(method, args, {asking: asking, random_node: try_random_node})
        rescue Errno::ECONNREFUSED, Redis::TimeoutError, Redis::CannotConnectError, Errno::EACCES
          try_random_node = true
          sleep 0.1 if ttl < Configuration::REQUEST_TTL/2
        rescue => e
          err_code = e.to_s.split.first
          raise e if !%w(MOVED ASK).include?(err_code)

          if err_code == "ASK"
             asking = true
          else
            reload_pool_nodes
            sleep 0.1 if ttl < Configuration::REQUEST_TTL/2
          end
        end
      end
    end

    def method_missing(method, *args, &block)
      execute(method, args)
    end

    private

    def reload_pool_nodes
      return if @locking
      @locking = true
      @startup_hosts.each do |options|
        begin
          redis = Node.redis(options)
          slots_mapping = redis.cluster("slots").group_by{|x| x[2]}
          @pool.delete_except!(slots_mapping.keys)
          slots_mapping.each do |host, infos|
            slots_ranges = infos.map {|x| x[0]..x[1] }
            @pool.add_node!({host: host[0], port: host[1]}, slots_ranges)
          end
        rescue
          next
        end
        break
      end
      @locking = false
      fresh_startup_nodes
    end

    def fresh_startup_nodes
      @pool.nodes.each {|node| @startup_hosts.push(node.host_hash) }
      @startup_hosts.uniq!
    end

  end # end client

end