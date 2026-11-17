///|
test "crop intersects negative and overflowing selections with source pixels" {
  @test_support.expect_json(
    crop_rect(
      (
        #|{"sourceWidth":1920,"sourceHeight":1080,"x":-10,"y":1060,"width":100,"height":50}
      ),
    ),
    (
      #|{"ok":true,"rect":{"x":0,"y":1060,"width":90,"height":20}}
    ),
  )
  @test_support.expect_json(
    crop_rect(
      (
        #|{"sourceWidth":1920,"sourceHeight":1080,"x":0,"y":0,"width":1920,"height":1080}
      ),
    ),
    (
      #|{"ok":true,"rect":{"x":0,"y":0,"width":1920,"height":1080}}
    ),
  )
}

///|
test "empty fractional and oversized crops return structured errors" {
  @test_support.expect_error(
    crop_rect(
      (
        #|{"sourceWidth":100,"sourceHeight":100,"x":100,"y":0,"width":10,"height":10}
      ),
    ),
    "empty_crop",
  )
  for width in ["0", "-1", "0.5", "1e100"] {
    @test_support.expect_error(
      crop_rect(
        "{\"sourceWidth\":100,\"sourceHeight\":100,\"x\":0,\"y\":0,\"width\":\{width},\"height\":10}",
      ),
      "invalid_input",
    )
  }
}
