---
title: "Setting Up Cloudflare Dynamic Dns on Kubernetes"
date: 2019-01-07T05:03:36-05:00
archives: "2019"
tags: ["Kubernetes", "go", "golang", "Cloudflare"]
author: Zachary Blanton
---

# Setting Up Cloudflare Dynamic DNS On Kubernetes

I'm currently working on switching all of my home infrastructure to Kubernetes including the blog you're reading now. My ISP luckily doesn't block port 80 and 443 so I can simply let Cloudflare point to my public IP. The problem is my IP is dynamic and can change at any point. So I needed something that can watch for my IP to change and then update Cloudflare with the new address. Rewind to about a year ago I wrote a small piece of software with Go that grabs the current IP set in Cloudflare and compares it with my current public IP. I'll use this and also take advantage of Kubernetes cron so that the pod doesn't need to run all the time.

## Creating the Docker image
If you're not interested in how I created the Docker image and simply want to use the one I've created on DockerHub you can skip this section.

I haven't played with multi-stage docker builds yet and figured this was a perfect time since I didn't have any binaries compiled for alpine. The first stage will be a builder that will pull down the source from <https://github.com/zbblanton/cloudflare_dynamic_dns.git> and then build the binary. Then the second stage will be a bare alpine image that the binary will get copied too. Below is the Dockerfile:

``` dockerfile
FROM golang:1.10.4-alpine3.8 as builder

WORKDIR /go/src

RUN apk --no-cache add git && \
    git clone https://github.com/zbblanton/cloudflare_dynamic_dns.git && \
    cd cloudflare_dynamic_dns && \
    go build

FROM alpine:3.8

RUN apk --no-cache add ca-certificates && \
    addgroup -S app && adduser -S -g app app && \
    mkdir -p /home/app/config #Create a config folder in case of bind-mounts

WORKDIR /home/app

COPY --from=builder /go/src/cloudflare_dynamic_dns/cloudflare_dynamic_dns .

RUN chown -R app /home/app

USER app

CMD ["./cloudflare_dynamic_dns", "--config=config/config.json"]
```

I've fallen in love with multi-stage Dockerfiles. The final image comes out to be about 18MB. I've published this docker image and you can pull it down with `docker pull zbblanton/cloudflare_dynamic_dns:latest`

## Create a Kubernetes secret for the config file
Create a file called `config.json` file and add:

``` json
{
  "cloudflare_api": {
    "auth_email": "user@site.com",
    "api_key": "XXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "zone_id": "XXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "dns_record_name": "my.site.com"
  },
  "smtp": {
    "enable": false
  },
  "public_ip_urls": [
    "http://icanhazip.com/",
    "http://myexternalip.com/raw",
    "http://ifconfig.me/ip"
  ],
  "interval": 1
}
```

You will need to get and replace `auth_email` with your cloudflare email, `api_key` with your Cloudflare API key, `zone_id` you can find this in the API section of your domain, and finally the `dns_record_name` with your current dns.

Now lets create the kubernetes secret:
``` bash
kubectl create secret generic cf-dynamic-dns-config --from-file=config.json=config.json
```

## Create a Kubernetes CronJob

We need to run the container on a schedule so that we can repeatedly look for our public IP to change. We will take advantage of CronJobs on Kubernetes to accomplish this.

Create a file called something like `cf-dynamic-dns.yml`

``` yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: cf-dynamic-dns
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      backoffLimit: 0     
      template:
        spec:          
          volumes:
          - name: config
            secret:
              secretName: cf-dynamic-dns-config
          containers:
          - name: cf-dynamic-dns
            image: zbblanton/cloudflare_dynamic_dns:latest
            env:
            - name: CF_CRON
              value: "true"
            volumeMounts:
            - mountPath: "/home/app/config"
              readOnly: true
              name: config
          restartPolicy: Never
```

NOTE: The `backoffLimit: 0` tells the job to do 0 retries.

This CronJob configures the cf-dynamic-dns container to use the secret config file and will run the container every minute. 

Now let's apply it to kubernetes:
``` bash
kubectl apply -f cf-dynamic-dns.yml
```

That's it! We should now have a scheduled job runs every minute and checks our public IP, if it changes update our Cloudflare DNS.
