provider "aws" {
  region  = "us-east-1"
}

data "aws_iam_policy_document" "public" {
  statement {
    sid = "PublicReadGetObject"
    
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::static-blog-blantontechnology/*",
    ]
  }
}

resource "aws_s3_bucket" "blog" {
  bucket = "static-blog-blantontechnology"
  acl    = "public-read"

  policy = data.aws_iam_policy_document.public.json
  
  website {
    index_document = "index.html"
    error_document = "404.html"
  }
}

resource "aws_iam_user" "github_actions_user" {
  name = "github-actions-blog"
}

data "aws_iam_policy_document" "github_actions_user_policy_document" {

  statement {
    actions = [
      "s3:HeadBucket",
    ]

    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
       "arn:aws:s3:::static-blog-blantontechnology",
       "arn:aws:s3:::static-blog-blantontechnology/*"
    ]
  }
}

resource "aws_iam_user_policy" "github_actions_user_policy" {
  name = "s3-access"
  user = aws_iam_user.github_actions_user.name

  policy = data.aws_iam_policy_document.github_actions_user_policy_document.json
}

resource "aws_iam_access_key" "access_key" {
  user = aws_iam_user.github_actions_user.name
}

output "github_actions_user_access_id" {
  value = aws_iam_access_key.access_key.id
}

output "github_actions_user_secret_id" {
  value = aws_iam_access_key.access_key.secret
}