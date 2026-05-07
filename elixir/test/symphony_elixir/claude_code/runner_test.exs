defmodule SymphonyElixir.ClaudeCode.RunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Runner

  test "locate_binary! returns absolute paths verbatim" do
    assert Runner.locate_binary!("/usr/bin/true") == "/usr/bin/true"
  end

  test "locate_binary! expands ~ in user-relative paths" do
    target = Path.join(System.tmp_dir!(), "symphony-runner-bin-#{System.unique_integer([:positive])}")
    File.write!(target, "")

    on_exit(fn -> File.rm(target) end)

    home = System.user_home!()
    relative_to_home = Path.relative_to(target, home)

    if relative_to_home == target do
      # tmp_dir is not under $HOME on this machine — fall back to a
      # synthetic ~ path to assert expansion behavior independently.
      assert Runner.locate_binary!("~/foo/bar") == Path.expand("~/foo/bar")
    else
      tilde_path = Path.join("~", relative_to_home)
      assert Runner.locate_binary!(tilde_path) == Path.expand(tilde_path)
    end
  end

  test "locate_binary! falls back to PATH lookup for bare names" do
    assert Runner.locate_binary!("sh") == System.find_executable("sh")
  end

  test "locate_binary! raises for missing bare names" do
    assert_raise ArgumentError, ~r/not found on PATH/, fn ->
      Runner.locate_binary!("definitely-not-a-real-binary-xyzzy")
    end
  end
end
