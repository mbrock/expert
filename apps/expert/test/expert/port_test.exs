defmodule Expert.PortTest do
  use ExUnit.Case, async: false

  alias Expert.Port
  alias Forge.Document
  alias Forge.Project

  test "find_project_executable removes release paths from shell-derived PATH" do
    tmp_dir = Path.join(System.tmp_dir!(), "expert-port-test-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(tmp_dir, "bin")
    release_root = Path.join(tmp_dir, "release")
    release_bin = Path.join(release_root, "bin")
    release_erts_bin = Path.join([release_root, "erts-1", "bin"])
    shell_path = Path.join(tmp_dir, "fake_shell.sh")
    erl_path = Path.join(bin_dir, "erl")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(release_bin)
    File.mkdir_p!(release_erts_bin)

    File.write!(shell_path, """
    #!/bin/sh
    while [ "$1" != "-c" ]; do
      shift
    done
    shift
    exec /bin/sh -c "$1"
    """)

    File.write!(erl_path, "#!/bin/sh\nexit 0\n")

    File.chmod!(shell_path, 0o755)
    File.chmod!(erl_path, 0o755)

    restore_env = capture_env(~w(PATH RELEASE_ROOT SHELL))

    on_exit(fn ->
      restore_env.(~w(PATH RELEASE_ROOT SHELL))
      File.rm_rf(tmp_dir)
    end)

    System.put_env("PATH", Enum.join([release_erts_bin, release_bin, bin_dir], ":"))
    System.put_env("RELEASE_ROOT", release_root)
    System.put_env("SHELL", shell_path)

    project = Project.bare(Document.Path.to_uri(tmp_dir))

    assert {:ok, found_erl, env} = Port.find_project_executable(project, "erl")
    assert to_string(found_erl) == erl_path
    assert List.keyfind(env, "PATH", 0) == {"PATH", bin_dir}
  end

  defp capture_env(keys) do
    values = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    fn restore_keys ->
      Enum.each(restore_keys, fn key ->
        case Map.fetch!(values, key) do
          nil -> System.delete_env(key)
          value -> System.put_env(key, value)
        end
      end)
    end
  end
end
