---
title: "Building a Jenkins Pipeline for the Blog"
date: 2019-01-12T21:16:02-05:00
archives: "2019"
tags: ["groovy", "jenkins", "Cloudflare"]
author: Zachary Blanton
---

# Building a Jenkins Pipeline for the Blog
Currently it's a pain to publish posts or edit this blog. I develop the blog locally with the built in web server that comes with Hugo. Then once I'm done making a post or modifying the site I run `hugo` and it compiles all my markdown into HTML. Once compiled I push my site to GitHub. From this point I have to manually pull the repo down, build a new docker image, push it, then deploy the new image as a function on OpenFaaS. Let's automate this with a Jenkins pipeline job. By the end of this I want the pipeline to watch my git repo for changes and then deploy the new blog function to OpenFaaS. I want to build this pipeline without using the faas-cli on OpenFaaS since the only piece I really need it for is updating the blog function on OpenFaaS.

Lets break the pipeline down and figure out what stages we want:

1. Git clone the repo.
2. Copy the static files to the function folder.
3. Build the Docker image for OpenFaaS.
4. Push the Docker image to the private registry.
5. Deploy the new function to OpenFaaS.
6. Clean up our workspace.

Now lets figure out each piece of the stage and then bring everything together. We will skip the pretty easy steps like cloning, copying files, and pushing the image.

## Build the Docker Image for OpenFaaS
To deploy our site to OpenFaaS we need to build a new docker image every time our site changes. To do this I simply copied the build directory from my OpenFaaS function. This includes the Dockerfile, main.go, and our function folder. The function folder is where our web files will be stored. The resulting structure is this [repository](https://github.com/zbblanton/blog_pipeline).

Once the file structure is setup correctly we can simple do a docker build from the shell. In my case:
``` bash
docker build -t localhost:5000/bt-blog .
```

## Deploy the New Function to OpenFaaS
Since we don't want to install faas-cli we will need to manually make the call to the OpenFaaS API to update our blog function. Looking through the Swagger reference we can see this is a `PUT` call to `/system/functions` with a JSON payload in the body. The JSON will look like this for my blog:
``` json
{
    "service": "blog",
    "image": "localhost:5000/bt-blog",
    "labels": {
        "com.openfaas.scale.zero": "true"
    }
}
```

OpenFaaS also requires API authentication in the header. I store the token in a Jenkins credential as secret text and call it `openfaasPass`. In the pipeline this gets saved as an environment variable and is used in the script to authenticate.

So lets actually make the script to call the API with curl:
``` groovy
reqJSON = '''
        {
            "service": "blog",
            "image": "localhost:5000/bt-blog",
            "labels": {
                "com.openfaas.scale.zero": "true"
            }
        }
        '''
resp = sh(returnStdout: true, script: "curl -o /dev/null -s -w '%{http_code}' -X PUT http://192.168.0.10:31112/system/functions -H 'authorization: Basic " + env.OPENFAAS_PASS + "' -d '" + reqJSON + "'").trim()
if (resp != "200" && resp != "201" && resp != "202") {
    error("Updating function failed. Status code: " + resp)
}
echo resp
```

In the above script we set the return of curl as the status code and then check if it's successful. If it's not then stop the build.

## Building the Pipeline
Now let's actually tie everything together into a `Jenkinsfile`.
``` groovy
pipeline {
    agent any
    triggers {
        pollSCM('*/1 * * * *')
    }
    environment {
        OPENFAAS_PASS = credentials('openfaasPass')
    }
    stages {
        stage('Clone Blog Repo') {
            steps {
                dir('blog') {
                    git 'https://github.com/zbblanton/blog'
                }                
            }
        }
        stage('Copy Static Files') {
            steps {
                dir('function') {
                    sh 'cp -R ../blog/public .'
                }
            }
        }
        stage('Build New Function Image') {
            steps {
                sh 'docker build -t localhost:5000/bt-blog .'
            }
        }
        stage('Push New Image') {
            steps {
                sh 'docker push localhost:5000/bt-blog:latest'
            }
        }
        stage('Deploy New Function') {
            steps {
                script {
                    reqJSON = '''
                    {
                        "service": "blog",
                        "image": "localhost:5000/bt-blog",
                        "labels": {
                            "com.openfaas.scale.zero": "true"
                        }
                    }
                    '''
                    resp = sh(returnStdout: true, script: "curl -o /dev/null -s -w '%{http_code}' -X PUT http://192.168.0.10:31112/system/functions -H 'authorization: Basic " + env.OPENFAAS_PASS + "' -d '" + reqJSON + "'").trim()
                    if (resp != "200" && resp != "201" && resp != "202") {
                        error("Updating function failed. Status code: " + resp)
                    }
                    echo resp
                }
            }
        }
        stage('Clean Workspacee') {
            steps {
                cleanWs()
            }
        }
    }
}
```

You can see from the code I use `pollSCM('*/1 * * * *')` to check our repo every minute for changes.

## Pitfalls
The golang template for OpenFaaS is copied into the repo. Therefore it won't be updated periodically. This is easily fixed by manually pulling down the template from git but it's not something I'm worried about at the moment.

## Improvements
Sometimes there are caching issues with CloudFlare and the blog in which I end up having to purge the cache. This could be a step to introduce later on.

