defmodule SymphonyElixir.Agent.BinaryResolverTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.BinaryResolver

  test "returns absolute paths verbatim" do
    assert BinaryResolver.resolve!("/usr/bin/true") == "/usr/bin/true"
  end

  test "expands ~ in user-relative paths" do
    target = Path.join(System.tmp_dir!(), "symphony-resolver-bin-#{System.unique_integer([:positive])}")
    File.write!(target, "")
    on_exit(fn -> File.rm(target) end)

    home = System.user_home!()
    relative_to_home = Path.relative_to(target, home)

    if relative_to_home == target do
      assert BinaryResolver.resolve!("~/foo/bar") == Path.expand("~/foo/bar")
    else
      tilde_path = Path.join("~", relative_to_home)
      assert BinaryResolver.resolve!(tilde_path) == Path.expand(tilde_path)
    end
  end

  test "falls back to PATH lookup for bare names" do
    assert BinaryResolver.resolve!("sh") == System.find_executable("sh")
  end

  test "raises ArgumentError for missing bare names" do
    assert_raise ArgumentError, ~r/not found on PATH/, fn ->
      BinaryResolver.resolve!("definitely-not-a-real-binary-xyzzy")
    end
  end

  test ":label option customizes the error message" do
    assert_raise ArgumentError, ~r/codex binary "definitely-not-real-xyz" not found on PATH/, fn ->
      BinaryResolver.resolve!("definitely-not-real-xyz", label: "codex")
    end
  end
end
