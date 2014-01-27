defmodule Kernel.ParallelRequire do
  @moduledoc """
  A module responsible for requiring files in parallel.
  """

  defmacrop default_callback, do: quote(do: fn x -> x end)

  @doc """
  Requires the given files.

  A callback that is invoked every time a file is required
  can be optionally given as argument.

  Returns the modules generated by each required file.
  """
  def files(files, callback \\ default_callback) do
    schedulers = max(:erlang.system_info(:schedulers_online), 2)
    spawn_requires(files, [], callback, schedulers, [])
  end

  defp spawn_requires([], [], _callback, _schedulers, result), do: result

  defp spawn_requires([], waiting, callback, schedulers, result) do
    wait_for_messages([], waiting, callback, schedulers, result)
  end

  defp spawn_requires(files, waiting, callback, schedulers, result) when length(waiting) >= schedulers do
    wait_for_messages(files, waiting, callback, schedulers, result)
  end

  defp spawn_requires([h|t], waiting, callback, schedulers, result) do
    parent = self

    compiler_pid    = :erlang.get(:elixir_compiler_pid)
    ensure_compiled = :erlang.get(:elixir_ensure_compiled)
    { :error_handler, handler } = :erlang.process_info(parent, :error_handler)

    { pid, ref } = :erlang.spawn_monitor fn ->
      if compiler_pid != :undefined do
        :erlang.put(:elixir_compiler_pid, compiler_pid)
      end

      if ensure_compiled != :undefined do
        :erlang.put(:elixir_ensure_compiled, ensure_compiled)
      end

      :erlang.process_flag(:error_handler, handler)

      exit(try do
        new = Code.require_file(h) || []
        { :required, Enum.map(new, &elem(&1, 0)), h }
      catch
        kind, reason ->
          { :failure, kind, reason, System.stacktrace }
      end)
    end

    spawn_requires(t, [{ pid, ref }|waiting], callback, schedulers, result)
  end

  defp wait_for_messages(files, waiting, callback, schedulers, result) do
    receive do
      { :DOWN, ref, :process, pid, status } ->
        tuple = { pid, ref }
        if tuple in waiting do
          case status do
            { :required, mods, file } ->
              callback.(file)
              result  = mods ++ result
              waiting = List.delete(waiting, tuple)
            { :failure, kind, reason, stacktrace } ->
              :erlang.raise(kind, reason, stacktrace)
            other ->
              :erlang.raise(:exit, other, [])
          end
        end
        spawn_requires(files, waiting, callback, schedulers, result)
    end
  end
end
