class Router
  def call(env)
    request = Rack::Request.new(env)

    case request.path
    when "/posts"
      controller = PostsController.new
      response_body = controller.index
      [200, {"Content-Type" => "application/json"}, [response_body]]
    else
      [404, {"Content-Type" => "text/plain"}, ["Not Found"]]
    end
  end
end
