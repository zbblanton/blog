---
title: "Building a Web Server on OpenFaaS"
date: 2019-01-06T04:02:20-05:00
archives: "2019"
tags: ["OpenFaaS", "Kubernetes", "go", "golang"]
author: Zachary Blanton
---

# Building a Web Server on OpenFaaS

Recently I've been playing around with OpenFaaS on Kubernetes and I've been looking for a small project to run on it. I've also wanted to start this static blog and figured this is a perfect project to run on OpenFaaS.

## Prerequisites
Before we start make sure you have installed OpenFaaS on Kubernetes. This can be done in a few commands if you already have Helm installed. If you don't follow this guide to get Helm installed:
<https://docs.helm.sh/using_helm/#install-helm>

You can follow this README to set up OpenFaaS:
<https://github.com/openfaas/faas-netes/blob/master/chart/openfaas/README.md>

## Walkthrough

First lets create our function (I'm calling it blog but you can name it anything you like):

``` bash
mkdir blog
cd blog
faas template pull https://github.com/openfaas-incubator/golang-http-template
faas new --lang golang-middleware blog
```

The first command above will pull the golang http template down so our CLI can use it.

Now lets write a very simple http server using golang. Open up the handler.go file (Something like blog/blog/handler.go) and rewrite it with:

``` golang
package function

import (
        "net/http"
)

func Handle(w http.ResponseWriter, r *http.Request) {
        path := r.URL.Path
        if string(path[len(path)-1]) == "/" {
                path = path + "index.html"
        }
        http.ServeFile(w, r, "public/"+path)
}
```

This is a really simple handler function that first checks if our request path ends with `/` if so lets add index.html. Now
we can use that path to serve our file. This works because OpenFaaS modifies our request path before the handler sees it. So if we make a function call to <http://myfaas.com/function/blog/page1/page.html>, our path is set to `page1/page.html`.

All our web files are located inside the public folder. For example if we had a bunch of static files, first make a folder called public in the same folder as the handler.go and then paste all your static content inside public.

**Note**: The public folder is just preference, you can name it any folder you like. Just make sure to change the public folder in the function code above.

Now if you go ahead and build this you will end up with a docker image that seems ready to go and you can push it to OpenFaaS. But there is actually an issue in the dockerfile where it does not copy over any files other than handler.go in the build. To solve this we need to make an edit inside the dockerfile for the template. Edit blog/template/golang-middleware/Dockerfile and add the following two lines after "COPY --from=build /usr/bin/fwatchdog ." 
``` dockerfile
COPY --from=build /go/src/handler/function/  .
RUN chown -R app /home/app
```
The lines above will copy all our files into the container and make sure the files are owned correctly.

I've opened up a [PR](https://github.com/openfaas-incubator/golang-http-template/pull/17) that fixes the copy problem. If it's accepted and merged I'll update this post.

Before we build, if you have multiple worker nodes on Kubernetes you will need to push your build to a registry. This can be your public DockerHub or a private one. Either way if this is the case you need to modify the blog.yml file and set the image correctly. For example if you have a private registry at registry.example.com:5000 then change the image line in the file to something like registry.example.com:5000/blog. Now push the image to the registry with:
``` bash
faas-cli push blog -f blog.yml
```

Now we ready to build our function! Run this command in the root of our project:
``` bash
faas-cli build blog -f blog.yml
```

If all went well, we now have a function ready to deploy to OpenFaaS. But before we deploy it, we want the function to scale to 0 if the website is not being hit. This essientially turns the function off until it's called. Once this happens the function starts up in about 2-3 seconds and will continue to run until the website stops getting hit and is idle for about 5 minutes.

To do this we take advantage of the [Zero-scale](https://docs.openfaas.com/architecture/autoscaling/#zero-scale) you can follow this github page <https://github.com/openfaas-incubator/faas-idler> for install instruction but essentially you copy the `faas-idler-dep.yml` from the repo, change the line with `- -dry-run=true` to `- -dry-run=false` and then run:
```
kubectl apply -f faas-idler-dep.yml
```

We are now ready to deploy our function! Simply run the following command to deploy the function with Zero-scale enabled.
```
faas-cli deploy blog -f blog.yml --label "com.openfaas.scale.zero=true"
```
**NOTE**: If you dont want Zero-scale you can just exclude the `--label "com.openfaas.scale.zero=true"`.

You should now be able to goto your browser and check if your static website is running. So for example if you have an index.html file inside the public folder and OpenFaaS is running on `192.168.0.10:31112` then your should be able to browse to <http://192.168.0.10:31112/function/blog> and view your file.
