# bench/ does not exist until M2, and a wildcard that matches nothing is not an error.
[
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test,dev,bench}/**/*.{ex,exs}"]
]
