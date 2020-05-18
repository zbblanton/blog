---
title: "Creating a Kubernetes Controller"
date: 2020-05-11T02:23:05-04:00
archives: "2020"
tags: ["Kubernetes", "go", "golang"]
author: Zachary Blanton
---

# Creating a Kubernetes Controller

Lately I've been trying to get deeper into Kubernetes whether I'm learning best practices or trying to develop tools on and for the platform. This lead me down the road to learning how to create a controller for Kubernetes. Turns out, this wasn't a very smooth road.

The current implementation for the controller is located at https://github.com/zbblanton/cloudflare_dynamic_dns_controller.

## The Goal

I've been wanting to build a controller for Kubernetes that runs in the cluster but didn't have any ideas until I thought of doing some simple dynamic DNS for Cloudflare. Honestly there is probably something out there that does something similar like the awesome [external-dns](https://github.com/kubernetes-sigs/external-dns) but this project for more about learning how to build a controller.

The goal is to build a Kubernetes controller that does two things, watch my public IP and sync my public IP with Cloudflare records that are given by either a service or an ingress resource annotations. So for example, if we have a service with the correct annotations for site1.example.com then the controller will be responsible for making sure the A record in Cloudflare has my current public IP.

## Watching my public IP

Before I talk about how I built my controller. Let's quickly take a look at how I get my public IP for Cloudflare to use.

``` go
func getPublicIP() (ip string, err error) {
	resp, err := http.Get("http://api.ipify.org")
	if err != nil {
		return "", err
	}
	publicIPRaw, err := ioutil.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return "", err
	}

	return string(publicIPRaw), nil
}
```

From the code above I simply do a get request to api.ipify.org to retrieve my public IP and then return it as a string. I keep the IP a string because I don't really ever have a need to convert it to an IP in go. This could be changed to provide better verification for IP's.

Not only do I need my public IP I also need a tread-safe way to retrieve it since we will be using multiple go routines that could access the public IP:

``` go
type CurrentIP struct {
	ip  string
	mux sync.Mutex
}

func (c *CurrentIP) Get() string {
	c.mux.Lock()
	defer c.mux.Unlock()
	return c.ip
}

func (c *CurrentIP) Set(ip string) {
	c.mux.Lock()
	c.ip = ip
	c.mux.Unlock()
}
```

Finally I need to watch the IP for changes:

``` go
func watchPublicIP(currentIP *CurrentIP) {
	ticker := time.NewTicker(30 * time.Second)
	for {
		publicIP, err := getPublicIP()
		if err != nil {
			println("Could not retrieve IP. Retry on next check...")
		}
		if currentIP.Get() != publicIP {
			currentIP.Set(publicIP)
		}
		println(currentIP.Get())
		<-ticker.C
	}
}
```

The code above creates a ticker that runs the for loop every 30 seconds to check if the current saved IP is equal to the new IP.

## What is a controller in Kubernetes?
A Kubernetes controller is usually something that watches Kubernetes state and then does really anything you want. That's pretty vague but you can do whatever you want with the controller. An example would be the [aws ingress controller](https://kubernetes-sigs.github.io/aws-alb-ingress-controller/) that always watches for ingress or service resources that have certain annotation in the metadata and then creates a load balancer using the annotations values.

The specific type of controller implementation I will talk about is the [client-go](https://github.com/kubernetes/client-go) library from Kubernetes. It's used in by the Kubernetes team to create [kubectl](https://kubernetes.io/blog/2018/01/introducing-client-go-version-6/) and used by outside developers to create external tools like the Prometheus operator. This library provides tools that make it sort of easy to create controllers. I say sorta because I struggled for a bit.

## How I built my controller
I read several articles and tutorials about controllers and spent hours looking at the client-go source code along with other examples. The best example I found and ended up designing around was the [workqueue example](https://github.com/kubernetes/client-go/tree/master/examples/workqueue) from the client-go library. I recommend reading through the code to understand what's happening. Long story short this pretty much creates a copy of all the resources you want to watch, adds them to the queue, and then loops through the queue and decides if any action needs be done.

If you want to get a deeper understanding then take a look at this the diagram and explanation at [client-go](https://github.com/kubernetes/sample-controller/blob/master/docs/controller-client-go.md)

I'm going to show how I modified the workqueue example to work for me to build my controller whether it's a good way or not.

Before I started, I needed to figure out how I wanted to know if a record needed to be created in Cloudflare. I decided that I wanted to watch the service and ingress resources that had the annotations below.

``` yaml
cloudflare-dynamic-dns.alpha.kubernetes.io/hostname: "hello.example.com"
cloudflare-dynamic-dns.alpha.kubernetes.io/proxied: "true"
```

With this I could ask myself how the controller looks from the outside. The logic is pretty simple. Every time a service or ingress resource gets created/updated/deleted and has the annotations above, sync the Cloudflare DNS record with the hostname and also use Cloudflares proxy if needed. From there I could start to create the reflector. The reflector will watch the Kubernetes API for resources matching what you define. The workqueue example watched for pod resources. For me, I want to watch the service and ingress resources so I needed to actually create two reflectors.

``` go
serviceListWatcher := cache.NewListWatchFromClient(clientset.CoreV1().RESTClient(), "services", "", fields.Everything())
ingressListWatcher := cache.NewListWatchFromClient(clientset.NetworkingV1beta1().RESTClient(), "ingresses", "", fields.Everything())
```

Next, I needed to create the indexers and informers which pretty much just adds the resource name into the queue to be worked on later by the worker loop. In the workqueue example a couple callback functions were created to add, update, delete items from the cache. It uses the key name structure `namespace/name`. For the key name I decided to use the format `resourceType/namespace/name`, so for example `service/example-namespace/helloworld`. This allows me quickly distinguish later what resource type we are using. As with the reflectors above I have to create an indexer and informer for both the service and ingress resource. The code could be cleaned up some but looks like:

``` go
// create the workqueue
queue := workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter())

serviceIndexer, serviceInformer := cache.NewIndexerInformer(serviceListWatcher, &v1.Service{}, 60*time.Second, cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj interface{}) {
        key, err := cache.MetaNamespaceKeyFunc(obj)
        if err == nil {
            queue.Add("service/" + key)
        }
    },
    UpdateFunc: func(old interface{}, new interface{}) {
        key, err := cache.MetaNamespaceKeyFunc(new)
        if err == nil {
            queue.Add("service/" + key)
        }
    },
    DeleteFunc: func(obj interface{}) {
        // IndexerInformer uses a delta queue, therefore for deletes we have to use this
        // key function.
        key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
        if err == nil {
            queue.Add("service/" + key)
        }
    },
}, cache.Indexers{})

ingressIndexer, ingressInformer := cache.NewIndexerInformer(ingressListWatcher, &v1beta1.Ingress{}, 60*time.Second, cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj interface{}) {
        key, err := cache.MetaNamespaceKeyFunc(obj)
        if err == nil {
            queue.Add("ingress/" + key)
        }
    },
    UpdateFunc: func(old interface{}, new interface{}) {
        key, err := cache.MetaNamespaceKeyFunc(new)
        if err == nil {
            queue.Add("ingress/" + key)
        }
    },
    DeleteFunc: func(obj interface{}) {
        // IndexerInformer uses a delta queue, therefore for deletes we have to use this
        // key function.
        key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
        if err == nil {
            queue.Add("ingress/" + key)
        }
    },
}, cache.Indexers{})
```

NOTE: The `60*time.Second` above is saying to resync the resources from the API every 60 seconds. So not only do I watch for new resources I also want to sync up to make sure nothing was changed or deleted.

Moving on to the controller object, which is mostly the same from the workqueue example until `processNextItem`. Here I actually start my own logic and call `cloudflareSync`.

``` go
func (c *Controller) processNextItem() bool {
	// Wait until there is a new item in the working queue
	key, quit := c.queue.Get()
	if quit {
		return false
	}

	defer c.queue.Done(key)

	err := c.cloudflareSync(key.(string))
	c.handleErr(err, key)

	return true
}

func (c *Controller) runWorker() {
	for c.processNextItem() {
	}
}
```

You can see that each item gets popped from the queue then `err := c.cloudflareSync(key.(string))` will actually process the item. This function is where the meat is. Maybe too much meat and could be broken down but whatever. From this code you can see that first I use the key name to decide what type the current resource is from the queue. So, if it starts with "service" I know that it will be a service resource and I can do a type assertion as I retrieve the updated resource from the Kubernetes API. Once I have the resource, I check the annotations to see if I want to skip this resource or if I should continue checking if the Cloudflare record needs to be changed or not.

``` go
func (c *Controller) cloudflareSync(key string) error {
	var obj interface{}
	var exists bool
	var err error

	splitKey := strings.Split(key, "/")
	resource := splitKey[1] + "/" + splitKey[2]
	if splitKey[0] == "service" {
		obj, exists, err = c.serviceIndexer.GetByKey(resource)
	} else {
		obj, exists, err = c.ingressIndexer.GetByKey(resource)
	}

	if err != nil {
		klog.Errorf("Fetching object with key %s from store failed with %v", key, err)
		return err
	}

	if !exists {
		fmt.Printf("Service %s does not exist anymore\n", key)
		c.cloudflareDeleteRecordPair(key)
	} else {
		var annotations map[string]string
		if splitKey[0] == "service" {
			annotations = obj.(*v1.Service).GetAnnotations()
		} else {
			annotations = obj.(*v1beta1.Ingress).GetAnnotations()
		}

		if _, ok := annotations["cloudflare-dynamic-dns.alpha.kubernetes.io/hostname"]; !ok {
			fmt.Printf("Skipping: %v\n", key)
			return nil
		}
		hostname := annotations["cloudflare-dynamic-dns.alpha.kubernetes.io/hostname"]

		//Check if proxied is provided, if so convert to bool
		var proxied bool
		if _, ok := annotations["cloudflare-dynamic-dns.alpha.kubernetes.io/proxied"]; ok {
			proxied, err = strconv.ParseBool(annotations["cloudflare-dynamic-dns.alpha.kubernetes.io/proxied"])
			if err != nil {
				fmt.Printf("Could not convert cloudflare-dynamic-dns.alpha.kubernetes.io/proxied to bool for %v\n", key)
				return nil
			}
		}

		publicIP := c.currentIP.Get()
		c.cloudflareSyncRecordPair(key, hostname, publicIP, proxied)
		fmt.Printf("Sync/Add/Update %v, hostname: %v, ip: %v\n", key, hostname, publicIP)
	}

	return nil
}
```

Now I can pull everything together and create the controller. The controller is slightly modified to accept my public IP watcher and the Cloudflare API object.

``` go
cfAuthEmail := os.Getenv("CF_AUTH_EMAIL")
cfAuthToken := os.Getenv("CF_AUTH_TOKEN")
cfZoneID := os.Getenv("CF_ZONE_ID")
cf := NewCloudflare(cfAuthEmail, cfAuthToken, cfZoneID)

//Start the public ip watcher and wait until we get an IP
currentIP := CurrentIP{}
go watchPublicIP(&currentIP)
waitForPublicIP(&currentIP)
    
controller := NewController(&currentIP, cf, queue, serviceIndexer, serviceInformer, ingressIndexer, ingressInformer)

stop := make(chan struct{})
defer close(stop)
go controller.Run(1, stop)

// Wait forever
select {}
```

I didn't talk here about all the Cloudflare functions. If you want to see the code look at `controller.go` and `cloudflare.go` on my [repo](https://github.com/zbblanton/cloudflare_dynamic_dns_controller).


# Building the Controller
Since this is Go I can easily create a Dockerfile to build and run the controller. I currently use Docker Hub to automated my builds.

``` Dockerfile
FROM golang:alpine AS builder

ENV GO111MODULE=on
ENV GOPATH=""

WORKDIR /app

COPY . .

RUN go build -o controller .

FROM alpine

COPY --from=builder /app/controller /app/

CMD ["./app/controller"]
```

# Deploying the Controller
I used environment variables to inject the configuration into the pod. The variables are from a Kubernetes secret:

``` bash
kubectl create secret -n cloudflare-dynamic-dns-controller generic cloudflare --from-literal=email=INSERT-EMAIL --from-literal=token=INSERT-TOKEN --from-literal=zone=INSERT-ZONE-ID
```

The code uses the client-go libraries built in functions to create a kube config file when running inside the cluster. This allows me to use a service account and RBAC to grant the exact permissions needed to run the controller in the cluster.

``` yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/name: cloudflare-dynamic-dns-controller
  name: cloudflare-dynamic-dns-controller
rules:
  - apiGroups:
      - ""
      - extensions
    resources:
      - ingresses
      - services
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/name: cloudflare-dynamic-dns-controller
  name: cloudflare-dynamic-dns-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cloudflare-dynamic-dns-controller
subjects:
  - kind: ServiceAccount
    name: cloudflare-dynamic-dns-controller
    namespace: cloudflare-dynamic-dns-controller
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/name: cloudflare-dynamic-dns-controller
  name: cloudflare-dynamic-dns-controller
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/name: cloudflare-dynamic-dns-controller
  name: cloudflare-dynamic-dns-controller
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflare-dynamic-dns-controller
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflare-dynamic-dns-controller
    spec:
      containers:
        - name: cloudflare-dynamic-dns-controller
          env:
            - name: CF_AUTH_EMAIL
              valueFrom:
                secretKeyRef:
                  name: cloudflare
                  key: email
            - name: CF_AUTH_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflare
                  key: token
            - name: CF_ZONE_ID
              valueFrom:
                secretKeyRef:
                  name: cloudflare
                  key: zone
          image: docker.io/zbblanton/cloudflare_dynamic_dns_controller:latest
      serviceAccountName: cloudflare-dynamic-dns-controller
```

That's pretty much it! Looking through my code and the workqueue example should give you a decent idea on how to create a simple controller. I can't promise this is an idea way of creating controllers and I know pieces could be optimized but it worked for me. 

## Some thoughts
* The client-go library also provides several generators. I would like to eventually learn how to use those to create all the boilerplate code to help create controllers and even custom resource definitions.
* I noticed as I was writing this post that I could optimize how many keys are in the queue by moving the logic to check the annotations to the indexer and informer callback functions. This would mean that only the resources with the correct annotations are placed in the queue.

### Sources
https://medium.com/@cloudark/kubernetes-custom-controllers-b6c7d0668fdf
https://itnext.io/how-to-create-a-kubernetes-custom-controller-using-client-go-f36a7a7536cc
https://github.com/kubernetes/sample-controller
https://github.com/kubernetes/sample-controller/blob/master/docs/controller-client-go.md
https://github.com/kubernetes/sample-controller/blob/master/docs/images/client-go-controller-interaction.jpeg
https://github.com/kubernetes/client-go
https://github.com/kubernetes/client-go/tree/master/examples/workqueue
https://kubernetes.io/blog/2018/01/introducing-client-go-version-6/