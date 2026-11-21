defmodule CMS.Web.NodeController do
  use Phoenix.Controller
  
  def show(conn, %{"id" => id}) do
    node = CMS.Repo.get!(CMS.Node, id)
    render(conn, "show.json", node: node)
  end
end
