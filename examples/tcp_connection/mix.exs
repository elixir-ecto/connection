defmodule TCPConnection.Mixfile do
  use Mix.Project

  def project do
    [app: :tcp_connection,
     version: "0.0.1",
     elixir: "~> 1.0",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :connection]]
  end

  defp deps do
    [{:connection, [path: "../../"]}]
  end
end
