# frozen-string-literal: true

class Eventbox
  module ArgumentWrapper
    def self.build(method, name)
      parameters = method.parameters
      if parameters.find { |t, n| n.to_s.start_with?("€") }

        # Change a Proc object to a Method, so that we are able to differ between :opt and :req parameters.
        # This is because Ruby (wrongly IMHO) reports required parameters as optional.
        # The only way to get the true parameter types is through define_method.
        is_proc = Proc === method
        if is_proc
          cl = Class.new do
            define_method(:to_method, &method)
          end
          method = cl.instance_method(:to_method)
          parameters = method.parameters
        end

        decls = []
        convs = []
        rets = []
        parameters.each_with_index do |(t, n), i|
          case t
          when :req
            decls << n
            if n.to_s.start_with?("€")
              convs << "#{n} = WrappedObject.new(#{n}, source_event_loop, :#{n})"
            end
            rets << n
          when :opt
            decls << "#{n}=nil"
            if n.to_s.start_with?("€")
              convs << "#{n} = #{n} ? WrappedObject.new(#{n}, source_event_loop, :#{n}) : []"
            end
            rets << "*#{n}"
          when :rest
            decls << "*#{n}"
            if n.to_s.start_with?("€")
              convs << "#{n}.map!{|v| WrappedObject.new(v, source_event_loop, :#{n}) }"
            end
            rets << "*#{n}"
          when :keyreq
            decls << "#{n}:"
            if n.to_s.start_with?("€")
              convs << "#{n} = WrappedObject.new(#{n}, source_event_loop, :#{n})"
            end
            rets << "#{n}: #{n}"
          when :key
            decls << "#{n}:nil"
            if n.to_s.start_with?("€")
              convs << "#{n} = #{n} ? {#{n}: WrappedObject.new(#{n}, source_event_loop, :#{n})} : {}"
            else
              convs << "#{n} = #{n} ? {#{n}: #{n}} : {}"
            end
            rets << "**#{n}"
          when :keyrest
            decls << "**#{n}"
            if n.to_s.start_with?("€")
              convs << "#{n}.each{|k, v| #{n}[k] = WrappedObject.new(v, source_event_loop, :#{n}) }"
            end
            rets << "**#{n}"
          when :block
            if n.to_s.start_with?("€")
              raise "block to `#{name}' can't be wrapped"
            end
          end
        end
        code = "#{is_proc ? :proc : :lambda} do |source_event_loop#{decls.map{|s| ",#{s}"}.join }| # #{name}\n  #{convs.join("\n")}\n  [#{rets.join(",")}]\nend"
        instance_eval(code, "wrapper code defined in #{__FILE__}:#{__LINE__} for #{name}")
      end
    end
  end
end
