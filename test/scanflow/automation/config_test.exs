defmodule Scanflow.Automation.ConfigTest do
  use ExUnit.Case, async: false

  alias Scanflow.Automation.Config

  setup do
    previous = Application.get_env(:scanflow, :automation)
    Application.delete_env(:scanflow, :automation)

    on_exit(fn ->
      if previous do
        Application.put_env(:scanflow, :automation, previous)
      else
        Application.delete_env(:scanflow, :automation)
      end
    end)
  end

  test "the default black-and-white profile uses AirScan document enhancements" do
    assert Config.mode_args_map() == %{
             "bw" =>
               "--mode Gray --contrast 50 --highlight 80",
             "color" => "--mode Color"
           }
  end

  test "scanner-specific mode arguments remain configurable" do
    Application.put_env(:scanflow, :automation,
      scan_mode_args_map: "bw:--mode Gray --contrast 25,color:--mode Color"
    )

    assert Config.mode_args_map()["bw"] == "--mode Gray --contrast 25"
  end
end
