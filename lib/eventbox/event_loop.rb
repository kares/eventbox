class Eventbox
  # @private
  #
  # This class manages the calls to internal methods and procs comparable to an event loop.
  # It doesn't use an explicit event loop, but uses the calling thread to process the event.
  #
  # All methods prefixed with "_" requires @mutex acquired to be called.
  class EventLoop
    def initialize(threadpool, guard_time)
      @threadpool = threadpool
      @running_actions = []
      @running_actions_for_gc = []
      @mutex = Mutex.new
      @shutdown = false
      @guard_time_proc = case guard_time
        when NilClass
          nil
        when Numeric
          guard_time and proc do |dt, name|
            if dt > guard_time
              ecaller = caller.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) }
              warn "guard time exceeded: #{"%2.3f" % dt} sec (limit is #{guard_time}) in `#{name}' called from `#{ecaller}' - please move blocking tasks to actions"
            end
          end
        when Proc
          guard_time
        else
          raise ArgumentError, "guard_time should be Numeric, Proc or nil"
      end
    end

    # Abort all running action threads.
    def send_shutdown(object_id=nil)
#       warn "shutdown called for object #{object_id} with #{@running_actions.size} threads #{@running_actions.map(&:object_id).join(",")}"

      # The finalizer doesn't allow suspension per Mutex, so that we access a read-only copy of @running_actions.
      # To avoid race conditions with thread creation, set a flag before the loop.
      @shutdown = true

      # terminate all running action threads
      @running_actions_for_gc.each(&:abort)

      nil
    end

    def shutdown(&completion_block)
      send_shutdown
      if internal_thread?
        if completion_block
          completion_block = new_async_proc(&completion_block)

          @threadpool.new do
            @running_actions_for_gc.each(&:join)
            completion_block.call
          end
        end
      else
        raise InvalidAccess, "external shutdown call doesn't take a block but blocks until threads have terminated" if completion_block
        @running_actions_for_gc.each(&:join)
      end
    end

    # Make a copy of the thread list for use in shutdown.
    # The copy is replaced per an atomic operation, so that it can be read lock-free in shutdown.
    def _update_action_threads_for_gc
      @running_actions_for_gc = @running_actions.dup
    end

    # Is the caller running within the internal context?
    def internal_thread?
      @mutex.owned?
    end

    def synchronize_external
      if internal_thread?
        yield
      else
        @mutex.synchronize do
          yield
        end
      end
    end

    def with_call_frame(name, answer_queue)
      @mutex.lock
      begin
        @latest_answer_queue = answer_queue
        @latest_call_name = name
        start_time = Time.now
        yield
      ensure
        diff_time = Time.now - start_time
        @latest_answer_queue = nil
        @latest_call_name = nil
        @mutex.unlock
        @guard_time_proc&.call(diff_time, name)
      end
    end

    def async_call(box, name, args, block)
      with_call_frame(name, nil) do
        box.send("__#{name}__", *args, &block)
      end
    end

    def sync_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        res = box.send("__#{name}__", *args, &block)
        res = ArgumentSanitizer.sanitize_values(res, self, :extern)
        answer_queue << res
      end
    end

    def yield_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        box.send("__#{name}__", *args, _result_proc(answer_queue, name), &block)
      end
    end

    # Anonymous version of async_call
    def async_proc_call(pr, args, arg_block)
      with_call_frame(AsyncProc, nil) do
        pr.yield(*args, &arg_block)
      end
    end

    # Anonymous version of sync_call
    def sync_proc_call(pr, args, arg_block, answer_queue)
      with_call_frame(SyncProc, answer_queue) do
        res = pr.yield(*args, &arg_block)
        res = ArgumentSanitizer.sanitize_values(res, self, :extern)
        answer_queue << res
      end
    end

    # Anonymous version of yield_call
    def yield_proc_call(pr, args, arg_block, answer_queue)
      with_call_frame(YieldProc, answer_queue) do
        pr.yield(*args, _result_proc(answer_queue, pr), &arg_block)
      end
    end

    # Called when an external proc finished
    def external_proc_result(cbresult, res)
      with_call_frame(ExternalProc, nil) do
        cbresult.yield(*res)
      end
    end

    def new_async_proc(name=nil, &block)
      AsyncProc.new do |*args, &arg_block|
        if internal_thread?
          # called internally
          block.yield(*args, &arg_block)
        else
          # called externally
          args = ArgumentSanitizer.sanitize_values(args, self, self)
          arg_block = ArgumentSanitizer.sanitize_values(arg_block, self, self)
          async_proc_call(block, args, arg_block)
        end
        # Ideally async_proc{}.call would return the AsyncProc object to allow stacking like async_proc{}.call.call, but self is bound to the EventLoop object here.
        nil
      end
    end

    def new_sync_proc(name=nil, &block)
      SyncProc.new do |*args, &arg_block|
        if internal_thread?
          # called internally
          block.yield(*args, &arg_block)
        else
          # called externally
          answer_queue = Queue.new
          args = ArgumentSanitizer.sanitize_values(args, self, self)
          arg_block = ArgumentSanitizer.sanitize_values(arg_block, self, self)
          sync_proc_call(block, args, arg_block, answer_queue)
          callback_loop(answer_queue)
        end
      end
    end

    def new_yield_proc(name=nil, &block)
      YieldProc.new do |*args, &arg_block|
        if internal_thread?
          # called internally
          safe_yield_result(args, block)
          block.yield(*args, &arg_block)
          nil
        else
          # called externally
          answer_queue = Queue.new
          args = ArgumentSanitizer.sanitize_values(args, self, self)
          arg_block = ArgumentSanitizer.sanitize_values(arg_block, self, self)
          yield_proc_call(block, args, arg_block, answer_queue)
          callback_loop(answer_queue)
        end
      end
    end

    def safe_yield_result(args, name)
      complete = args.last
      unless Proc === complete
        if Proc === name
          raise InvalidAccess, "yield_proc #{name.inspect} must be called with a Proc object internally but got #{complete.class}"
        else
          raise InvalidAccess, "yield_call `#{name}' must be called with a Proc object internally but got #{complete.class}"
        end
      end
      args[-1] = proc do |*cargs, &cblock|
        unless complete
          if Proc === name
            raise MultipleResults, "received multiple results for #{name.inspect}"
          else
            raise MultipleResults, "received multiple results for method `#{name}'"
          end
        end
        res = complete.yield(*cargs, &cblock)
        complete = nil
        res
      end
    end

    private def _result_proc(answer_queue, name)
      new_async_proc(name) do |*resu|
        unless answer_queue
          if Proc === name
            raise MultipleResults, "received multiple results for #{name.inspect}"
          else
            raise MultipleResults, "received multiple results for method `#{name}'"
          end
        end
        resu = ArgumentSanitizer.return_args(resu)
        resu = ArgumentSanitizer.sanitize_values(resu, self, :extern)
        answer_queue << resu
        answer_queue = nil
      end
    end

    def wrap_proc(arg, name)
      if internal_thread?
        InternalObject.new(arg, self, name)
      else
        ExternalProc.new(arg, self, name) do |*args, &block|
          if internal_thread?
            # called internally
            if block && !(WrappedProc === block)
              raise InvalidAccess, "calling #{arg.inspect} with block argument #{block.inspect} is not allowed - use async_proc, sync_proc, yield_proc or an external proc instead"
            end
            cbblock = args.last if Proc === args.last
            _external_proc_call(arg, name, args, block, cbblock)
          else
            # called externally
            raise InvalidAccess, "external proc #{arg.inspect} #{"wrapped by #{name} " if name} should have been unwrapped externally"
          end
        end
      end
    end

    def callback_loop(answer_queue)
      loop do
        rets = answer_queue.deq
        case rets
        when EventLoop::Callback
          cbres = rets.block.yield(*rets.args, &rets.arg_block)

          if rets.cbresult
            cbres = ArgumentSanitizer.sanitize_values(cbres, self, self)
            external_proc_result(rets.cbresult, cbres)
          end
        else
          answer_queue.close if answer_queue.respond_to?(:close)
          return rets
        end
      end
    end

    # Mark an object as to be shared instead of copied.
    def shared_object(object)
      if internal_thread?
        ObjectRegistry.set_tag(object, self)
      else
        ObjectRegistry.set_tag(object, ExternalSharedObject)
      end
      object
    end

    def thread_finished(action)
      @mutex.synchronize do
        @running_actions.delete(action) or raise(ArgumentError, "unknown action has finished: #{action}")
        _update_action_threads_for_gc
      end
    end

    Callback = Struct.new :block, :args, :arg_block, :cbresult

    def _external_proc_call(block, name, args, arg_block, cbresult)
      if @latest_answer_queue
        args = ArgumentSanitizer.sanitize_values(args, self, :extern)
        arg_block = ArgumentSanitizer.sanitize_values(arg_block, self, :extern)
        @latest_answer_queue << Callback.new(block, args, arg_block, cbresult)
        nil
      else
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by `#{@latest_call_name}', which must a sync_call, yield_call or internal proc")
      end
    end

    def start_action(meth, name, args)
      qu = Queue.new

      new_thread = Thread.handle_interrupt(Exception => :never) do
        @threadpool.new do
          begin
            Thread.handle_interrupt(AbortAction => :on_blocking) do
              if meth.arity == args.length
                meth.call(*args)
              else
                meth.call(*args, qu.deq)
              end
            end
          rescue AbortAction
            # Do nothing, just exit the action
          rescue WeakRef::RefError
            # It can happen that the GC already swept the Eventbox instance, before some instance action is in a blocking state.
            # In this case access to the Eventbox instance raises a RefError.
            # Since it's now impossible to execute the action up to a blocking state, abort the action prematurely.
            raise unless @shutdown
          ensure
            thread_finished(qu.deq)
          end
        end
      end

      a = Action.new(name, new_thread, self)

      # Add to the list of running actions
      synchronize_external do
        @running_actions << a
        _update_action_threads_for_gc
      end

      # Enqueue the action twice (for call and for finish)
      qu << a << a

      # @shutdown is set without a lock, so that we need to re-check, if it was set while start_action
      if @shutdown
        a.abort
        a.join
      end

      a
    end
  end
end
