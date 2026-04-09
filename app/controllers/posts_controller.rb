class PostsController < Controller
  def index
    posts = Post.all

    render "index", posts:
  end

  def show(id:)
    post = Post.find(id)

    render "show", post:
  end
end
