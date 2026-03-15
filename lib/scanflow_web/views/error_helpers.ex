defmodule ScanflowWeb.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      ScanflowWeb.Gettext.lngettext(Gettext.get_locale(), "errors", msg, msg, count, opts)
    else
      ScanflowWeb.Gettext.lgettext(Gettext.get_locale(), "errors", msg, opts)
    end
  end
end
