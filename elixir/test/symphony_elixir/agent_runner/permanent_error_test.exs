defmodule SymphonyElixir.AgentRunner.PermanentErrorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner.PermanentError

  describe "exception/1" do
    test "requires :message and stores :reason verbatim" do
      err = PermanentError.exception(message: "boom", reason: {:port_exit, 127})

      assert err.message == "boom"
      assert err.reason == {:port_exit, 127}
    end

    test ":reason defaults to nil when not given" do
      err = PermanentError.exception(message: "no reason set")

      assert err.message == "no reason set"
      assert err.reason == nil
    end

    test "raises KeyError if :message is missing" do
      assert_raise KeyError, fn ->
        PermanentError.exception(reason: :no_message)
      end
    end
  end

  describe "from_exit?/1" do
    test "true for a {%PermanentError{}, stacktrace} tuple — the shape Task supervisor emits" do
      reason = {%PermanentError{message: "x", reason: nil}, [{__MODULE__, :__test__, 0, []}]}
      assert PermanentError.from_exit?(reason) == true
    end

    test "false for a RuntimeError exit — transient errors must NOT match" do
      reason = {%RuntimeError{message: "transient"}, []}
      refute PermanentError.from_exit?(reason)
    end

    test "false for :normal" do
      refute PermanentError.from_exit?(:normal)
    end

    test "false for an arbitrary tuple that happens to start with %PermanentError{} but no stacktrace list" do
      reason = {%PermanentError{message: "x"}, :not_a_stacktrace}
      refute PermanentError.from_exit?(reason)
    end
  end

  test "exception is actually raise/rescue-able via the exception protocol" do
    err =
      try do
        raise PermanentError, message: "raised", reason: {:port_exit, 127}
      rescue
        e in PermanentError -> e
      end

    assert err.message == "raised"
    assert err.reason == {:port_exit, 127}
  end
end
