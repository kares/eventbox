require_relative "../test_helper"

class EventboxTimersTest < Minitest::Test
  def diff_time
    st = Time.now
    yield
    Time.now - st
  end

  def test_delay_init
    eb = Class.new(Eventbox) do
      include Eventbox::Timers
      yield_call def init(interval, result)
        super()
        timers_after(interval) do
          result.yield
        end
      end
    end

    dt = diff_time { eb.new(0.01).shutdown! }
    assert_operator dt, :>=, 0.01
  end

  def test_after
    eb = Class.new(Eventbox) do
      include Eventbox::Timers

      yield_call def run(result)
        alerts = []
        timers_after(0.3) do
          alerts << 3
        end
        timers_after(0.1) do
          alerts << 1
          timers_after(0.05) do
            alerts << 0.5
          end
        end
        timers_after(0.2) do
          alerts << 2
        end
        timers_after(0.4) do
          result.yield alerts
        end
      end
    end.new

    alerts = eb.run
    assert_equal [1, 0.5, 2, 3], alerts
    eb.shutdown!
  end

  def test_every
    eb = Class.new(Eventbox) do
      include Eventbox::Timers

      yield_call def run(result)
        alerts = []
        timers_after(0.3) do
          alerts << 3
        end
        timers_every(0.1) do
          alerts << 1
          timers_after(0.05) do
            alerts << 0.5
          end
        end
        timers_after(0.2) do
          alerts << 2
        end
        timers_after(0.4) do
          result.yield alerts
        end
      end
    end.new

    alerts = eb.run
    assert_equal [1, 0.5, 2, 1, 0.5, 3, 1, 0.5], alerts
    eb.shutdown!
  end

  def test_cancel
    eb = Class.new(Eventbox) do
      include Eventbox::Timers

      yield_call def run(result)
        alerts = []
        timers_after(0.3) do
          alerts << 3
        end
        a1 = timers_every(0.1) do
          alerts << 1
          timers_after(0.05) do
            alerts << 0.5
          end
        end
        timers_after(0.22) do
          alerts << 2.2
          timers_cancel(a1)
        end
        timers_after(0.4) do
          result.yield alerts
        end
      end
    end.new

    alerts = eb.run
    assert_equal [1, 0.5, 1, 2.2, 0.5, 3], alerts
    eb.shutdown!
  end
end