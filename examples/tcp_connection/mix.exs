defmodule TCPConnection.Mixfile do
  use Mix.Project

  def project do
    [
      app: :tcp_connection,
      version: "0.1.0",
      elixir: "~> 1.7",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:connection, path: "../../"}
    ]
  end
end
