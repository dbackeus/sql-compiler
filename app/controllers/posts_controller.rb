class PostsController
  def index
    { posts: Post.all }.to_json
  end
end
