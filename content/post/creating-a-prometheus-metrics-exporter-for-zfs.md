---
title: "Creating a Prometheus Metrics Exporter for ZFS"
date: 2020-05-30T23:01:34-04:00
archives: "2020"
tags: ["go", "golang", "prometheus", "exporter"]
author: Zachary Blanton
---

# Creating a Prometheus Exporter for Proxmox ZFS

I'm starting to get into monitoring with Prometheus and Alertmanager. One of the first things I want to start monitoring is ZFS on my Proxmox server. I noticed that there isn't many exporters to scrape ZFS information so I decided to figure out how to create an exporter that can I can then use to monitor my ZFS zpools.

The source code for the end result is here: https://github.com/zbblanton/proxmox-zfs-exporter

I'm going to try a different format for this post and try to write it as I create the exporter.

So what I want is to create an exporter that prometheus can scrape that contains the current zpool state, if there are errors, the last scan time, and number of scan errors for each zpool.

Lets start by doing some research and I won't lie I already did some before I decided to write this post. Heres what I know so far:
* proxmox provides a pretty good API to use that gives me the information about zfs that I need.
* proxmox requires a "ticket" to authentication to the API as a cookie. You have to do a post request with some proxmox credentials to receive a payload with the ticket.

To create an authentication "ticket" we need to do a request. The Proxmox API documentation used curl in their example:
``` bash
curl -k -d "username=root@pam&password=yourpassword"  https://10.0.0.1:8006/api2/json/access/ticket 
```

Which returned:
``` json
{ 
    "data": { 
        "CSRFPreventionToken":"4EEC61E2:lwk7od06fa1+DcPUwBTXCcndyAY",  
        "ticket":"PVE:root@pam:4EEC61E2::rsKoApxDTLYPn6H3NNT6iP2mv...", 
        "username":"root@pam"
    }
}
```

Source: https://pve.proxmox.com/wiki/Proxmox_VE_API#Authentication

I opened Postman and grabbed the `ticket` from the response and created a cookie called `PVEAuthCookie` with the value set to the ticket.

![Postman](/img/postman.png)

Looking through the [API explorer](https://pve.proxmox.com/pve-docs/api-viewer/index.html) I got an idea of the calls I want to make. So with postman I created a GET request to `https://10.0.0.20:8006/api2/json/nodes/pve/disks/zfs` and got back my zpools:

``` json
{
    "data": [
        {
            "size": 2989297238016,
            "name": "storage",
            "dedup": 1,
            "alloc": 895623524352,
            "health": "ONLINE",
            "free": 2093673713664,
            "frag": 1
        },
        {
            "size": 255550554112,
            "alloc": 1351680,
            "health": "ONLINE",
            "name": "storage-nvme",
            "dedup": 1,
            "free": 255549202432,
            "frag": 0
        }
    ]
}
```

Knowing this, I can loop through all my zpools and get more information on the zpool by calling `https://10.0.0.20:8006/api2/json/nodes/pve/disks/zfs/storage` where `storage` is the name of one of my zpools. This returns:

``` json
{
    "data": {
        "scan": "scrub repaired 0B in 0 days 01:56:29 with 0 errors on Sun May 10 02:20:30 2020",
        "errors": "No known data errors",
        "leaf": 0,
        "action": "Enable all features using 'zpool upgrade'. Once this is done, the pool may no longer be accessible by software that does not support the features. See zpool-features(5) for details.",
        "children": [
            {
                "state": "ONLINE",
                "children": [
                    {
                        "cksum": 0,
                        "name": "/dev/sdb2",
                        "msg": "",
                        "read": 0,
                        "write": 0,
                        "leaf": 1,
                        "state": "ONLINE"
                    },
                    {
                        "msg": "",
                        "name": "/dev/sdc2",
                        "cksum": 0,
                        "state": "ONLINE",
                        "leaf": 1,
                        "write": 0,
                        "read": 0
                    }
                ],
                "name": "mirror-0",
                "cksum": 0,
                "leaf": 0,
                "write": 0,
                "read": 0,
                "msg": ""
            }
        ],
        "state": "ONLINE",
        "name": "storage",
        "status": "Some supported features are not enabled on the pool. The pool can still be used, but some features are unavailable."
    }
}
```

Ignore the supported feature information. That is from me moving my disks to another machine and not doing a zpool upgrade yet.

Now I need to figure out how to create a cookie in a go http request so that I can authenticate to the proxmox API. After some searching, I found it to be pretty simple with the http package: https://golang.org/pkg/net/http/#Request.AddCookie. I can create a request and then use the `AddCookie` function:

``` go
url := "https://api.cloudflare.com/client/v4/zones/" + c.ZoneID + "/dns_records?type=TXT"
//fmt.Println(url)
client := &http.Client{}
req, err := http.NewRequest("GET", url, nil)
if err != nil {
		return []CloudflareRecord{}, err
    }
cookie := http.Cookie{
    Name: "test"
    Value: "test"
}
req.AddCookie(&cookie)
```

I can start playing with some code now. I'll create a struct for the Proxmox API and then add some functions to it for calling the API.

``` go
type ProxmoxAPI struct {
	User   string
	Pass   string
	Host   string
	Port   string
	Ticket string
	mux    sync.Mutex
}
```

I need the mutex in the struct because multiple go routines could be accessing the same `ProxmoxAPI` struct. 

A note from the Proxmox documentation said that the `ticket` will expire every two hours. So I need to write some code that will grab a new ticket every one hour to be safe.

``` go
type ProxmoxAPITicketResp struct {
	Data struct {
		CSRFPreventionToken string `json:"CSRFPreventionToken"`
		Ticket              string `json:"ticket"`
		Username            string `json:"username"`
	} `json:"data"`
}

func (api *ProxmoxAPI) getTicket() string {
	api.mux.Lock()
	defer api.mux.Unlock()
	return api.Ticket
}

func (api *ProxmoxAPI) setTicket(ticket string) {
	api.mux.Lock()
	api.Ticket = ticket
	api.mux.Unlock()
}

func (api *ProxmoxAPI) GetAPITicket() (string, error) {
	//Copy the api vars so we can free the lock up
	api.mux.Lock()
	user := api.User
	pass := api.Pass
	host := api.Host
	port := api.Port
	api.mux.Unlock()

	url := "https://" + host + ":" + port + "/api2/json/access/ticket?username=" + user + "&password=" + pass
	c := &tls.Config{
		InsecureSkipVerify: true,
	}
	tr := &http.Transport{TLSClientConfig: c}
	client := &http.Client{Transport: tr}
	//client := &http.Client{}
	req, err := http.NewRequest("POST", url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Add("Content-type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close() //Close the resp body when finished

	respBody := ProxmoxAPITicketResp{}
	err = json.NewDecoder(resp.Body).Decode(&respBody)
	if err != nil {
		return "", err
	}

	return respBody.Data.Ticket, nil
}

func (api *ProxmoxAPI) refreshTicket() {
	ticker := time.NewTicker(time.Hour)
	for {
		newTicket, err := api.GetAPITicket()
		if err != nil {
			fmt.Println("Could not retrieve new ticket. Retry on next check...")
		}
		api.setTicket(newTicket)
		fmt.Println("Refreshed ticket")
		<-ticker.C
	}
}
```

Next, I need to figure out some best practices on creating an exporter. Some really good information from the docs for [prometheus](https://prometheus.io/docs/instrumenting/writing_exporters/#scheduling) is that the metrics should only be pulled when being scrape by Prometheus and not use its own timer. Which means anytime the `/metrics` endpoint is hit, the metrics should be scraped and then returned. This changes how I was originally planning to get metrics by caching the values and then letting the endpoint handler pulling the values (Which by the way, in the docs it says caching is okay but only if it's expensive to scrape on each request). After some more searching around I come along this really good tutorial: https://rsmitty.github.io/Prometheus-Exporters/. The article says I need to create a collector that implements the Prometheus collector interface. To do this I need to implement the `Describe` and `Collect` method.

To start I need to create all the metric descriptors, which is simply some metadata for each metric.

``` go
var (
	zpoolError = prometheus.NewDesc(
		"zfs_zpool_error",
		"Is there a zpool error",
		[]string{"node", "name"},
		nil,
	)
	zpoolOnline = prometheus.NewDesc(
		"zfs_zpool_online",
		"Is the zpool online",
		[]string{"node", "name"},
		nil,
	)
	zpoolFree = prometheus.NewDesc(
		"zfs_zpool_free",
		"Free space on zpool",
		[]string{"node", "name"},
		nil,
	)
	zpoolAllocated = prometheus.NewDesc(
		"zfs_zpool_allocated",
		"Allocated space on zpool",
		[]string{"node", "name"},
		nil,
	)
	zpoolSize = prometheus.NewDesc(
		"zfs_zpool_size",
		"Size of zpool",
		[]string{"node", "name"},
		nil,
	)
	zpoolDedup = prometheus.NewDesc(
		"zfs_zpool_dedup",
		"Is dedup enabled on zpool",
		[]string{"node", "name"},
		nil,
	)
	zpoolLastScrub = prometheus.NewDesc(
		"zfs_zpool_last_scrub",
		"Last zpool scrub",
		[]string{"node", "name"},
		nil,
	)
	zpoolLastScrubErrors = prometheus.NewDesc(
		"zfs_zpool_last_scrub_errors",
		"Last scrub total errors on the zpool",
		[]string{"node", "name"},
		nil,
	)
	zpoolParsingError = prometheus.NewDesc(
		"zfs_zpool_parsing_error",
		"Error when trying to parse the API data.",
		[]string{"node", "name"},
		nil,
	)
)
```

Implementing the `Describe` method is really easy. It's just a function that pushes each descriptor down the channel.

``` go
func (collector *proxmoxZpoolCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- zpoolError
	ch <- zpoolOnline
	ch <- zpoolFree
	ch <- zpoolAllocated
	ch <- zpoolSize
	ch <- zpoolDedup
	ch <- zpoolLastScrub
	ch <- zpoolLastScrubErrors
	ch <- zpoolParsingError
}
```

The `Collect` is where you actually start doing some logic. I won't lie this function is pretty bad and needs to be broken up but here ya go:

``` go
//Needs to be split up
func (collector *proxmoxZpoolCollector) Collect(ch chan<- prometheus.Metric) {
	nodes, err := collector.api.GetNodes()
	if err != nil {
		fmt.Println(err)
		return
	}
	for _, node := range nodes.Data {
		zpoolList, err := collector.api.GetZpoolList(node.Node)
		if err != nil {
			fmt.Println(err)
			return
		}
		for _, zpool := range zpoolList.Data {
			var zpoolParsingErrorMetric float64

			zpoolInfo, err := collector.api.GetZpool(node.Node, zpool.Name)
			if err != nil {
				zpoolParsingErrorMetric = float64(1)
				fmt.Println(err)
			}

			var zpoolOnlineMetric float64
			var zpoolErrorMetric float64
			if zpoolInfo.Data.State == "ONLINE" {
				zpoolOnlineMetric = float64(1)
				zpoolErrorMetric = float64(0)
			} else {
				zpoolErrorMetric = float64(1)
			}

			var zpoolLastScrubMetric float64
			//Example scrub response: scrub repaired 0B in 0 days 01:56:29 with 0 errors on Sun May 10 02:20:30 2020
			if x := strings.SplitAfter(zpoolInfo.Data.Scan, "on "); len(x) == 2 {
				//Sun May 10 02:20:30 2020
				if len(x[1]) > 5 { //We want to get rid of the day eg: Mon
					//May 10 02:20:30 2020
					t, err := time.Parse(dateForm, x[1][4:])
					if err != nil {
						zpoolParsingErrorMetric = float64(1)
						fmt.Println(err)
					}
					zpoolLastScrubMetric = float64(t.Unix()) //Could this be an issue since time.Unix() returns int64?
				}
			}

			var zpoolLastScrubErrorsMetric float64
			//Example scrub response: scrub repaired 0B in 0 days 01:56:29 with 0 errors on Sun May 10 02:20:30 2020
			splitLine := strings.Split(zpoolInfo.Data.Scan, " ")
			for index, x := range splitLine {
				if strings.Contains(x, "error") && index >= 1 { //Support for "error" or "errors"
					totalErrors, err := strconv.ParseFloat(splitLine[index-1], 64) //We want to grab the number before error eg: 3 errors
					if err != nil {
						zpoolParsingErrorMetric = float64(1)
					} else {
						zpoolLastScrubErrorsMetric = totalErrors
					}
					break
				}
			}

			ch <- prometheus.MustNewConstMetric(zpoolError, prometheus.GaugeValue, zpoolErrorMetric, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolOnline, prometheus.GaugeValue, zpoolOnlineMetric, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolFree, prometheus.GaugeValue, zpool.Free, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolAllocated, prometheus.GaugeValue, zpool.Alloc, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolSize, prometheus.GaugeValue, zpool.Size, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolDedup, prometheus.GaugeValue, float64(zpool.Dedup), node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolLastScrub, prometheus.GaugeValue, zpoolLastScrubMetric, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolLastScrubErrors, prometheus.GaugeValue, zpoolLastScrubErrorsMetric, node.Node, zpool.Name)
			ch <- prometheus.MustNewConstMetric(zpoolParsingError, prometheus.GaugeValue, zpoolParsingErrorMetric, node.Node, zpool.Name)
		}
	}
}
```

The main part here is at the end. For each metric, you just push it and it's value down the channel of the `Describe` function. Now I've implemented the collector interface and have the Prometheus client do the rest of the work:

``` go
func newProxmoxZpoolCollector(api *ProxmoxAPI) *proxmoxZpoolCollector {
	return &proxmoxZpoolCollector{
		name: name,
		api:  api,
	}
}

func main() {
	proxmoxAPI := readConfigFile()
	collector := newProxmoxZpoolCollector(proxmoxAPI)
	prometheus.MustRegister(collector)

	go proxmoxAPI.refreshTicket()
	//Wait for the first ticket to be set
	proxmoxAPI.waitForTicket()

	http.Handle("/metrics", promhttp.Handler())
	log.Fatal(http.ListenAndServe(":9000", nil))
}
```

Now after building, I can goto to my browser and look at the metrics:

```
# TYPE promhttp_metric_handler_requests_total counter
promhttp_metric_handler_requests_total{code="200"} 9590
promhttp_metric_handler_requests_total{code="500"} 0
promhttp_metric_handler_requests_total{code="503"} 0
# HELP zfs_zpool_allocated Allocated space on zpool
# TYPE zfs_zpool_allocated gauge
zfs_zpool_allocated{name="storage",node="pve"} 8.95623524352e+11
zfs_zpool_allocated{name="storage-nvme",node="pve"} 1.35168e+06
# HELP zfs_zpool_dedup Is dedup enabled on zpool
# TYPE zfs_zpool_dedup gauge
zfs_zpool_dedup{name="storage",node="pve"} 1
zfs_zpool_dedup{name="storage-nvme",node="pve"} 1
# HELP zfs_zpool_error Is there a zpool error
# TYPE zfs_zpool_error gauge
zfs_zpool_error{name="storage",node="pve"} 0
zfs_zpool_error{name="storage-nvme",node="pve"} 0
# HELP zfs_zpool_free Free space on zpool
# TYPE zfs_zpool_free gauge
zfs_zpool_free{name="storage",node="pve"} 2.093673713664e+12
zfs_zpool_free{name="storage-nvme",node="pve"} 2.55549202432e+11
# HELP zfs_zpool_last_scrub Last zpool scrub
# TYPE zfs_zpool_last_scrub gauge
zfs_zpool_last_scrub{name="storage",node="pve"} 1.58907723e+09
zfs_zpool_last_scrub{name="storage-nvme",node="pve"} 1.589070243e+09
# HELP zfs_zpool_last_scrub_errors Last scrub total errors on the zpool
# TYPE zfs_zpool_last_scrub_errors gauge
zfs_zpool_last_scrub_errors{name="storage",node="pve"} 0
zfs_zpool_last_scrub_errors{name="storage-nvme",node="pve"} 0
# HELP zfs_zpool_online Is the zpool online
# TYPE zfs_zpool_online gauge
zfs_zpool_online{name="storage",node="pve"} 1
zfs_zpool_online{name="storage-nvme",node="pve"} 1
# HELP zfs_zpool_parsing_error Error when trying to parse the API data.
# TYPE zfs_zpool_parsing_error gauge
zfs_zpool_parsing_error{name="storage",node="pve"} 0
zfs_zpool_parsing_error{name="storage-nvme",node="pve"} 0
# HELP zfs_zpool_size Size of zpool
# TYPE zfs_zpool_size gauge
zfs_zpool_size{name="storage",node="pve"} 2.989297238016e+12
zfs_zpool_size{name="storage-nvme",node="pve"} 2.55550554112e+11
```

Success! I now have metrics from the Proxmox API about my zfs zpools. To install the exporter on my Proxmox server I'll use systemd.

``` bash
wget https://github.com/zbblanton/proxmox-zfs-exporter/releases/download/v0.1.1/proxmox-zfs-exporter -O /usr/bin/proxmox-zfs-exporter
chmod +x /usr/bin/proxmox-zfs-exporter
cat > /etc/systemd/system/proxmox-zfs-exporter.service <<EOF
[Unit]
Description=Proxmox ZFS Exporter
Documentation=https://github.com/zbblanton/proxmox-zfs-exporter
[Service]
ExecStart=/usr/bin/proxmox-zfs-exporter
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable proxmox-zfs-exporter
systemctl start proxmox-zfs-exporter
```

Note: I skipped the creation of the config file. If you're interested check out the git repo.

Lastly I can tell Prometheus to start scraping the new metrics endpoint and setup some alerts that will notify me if anything happens to my zpools.

``` yaml
- name: monitoring
    rules:
    - alert: zpool_online
    expr: "zfs_zpool_online != 1"
    labels:
        severity: high
    annotations:
        summary: "State is not ONLINE for zpool: {{$labels.name}} on node: {{$labels.node}}"
        description: "State is not ONLINE for zpool: {{$labels.name}} on node: {{$labels.node}}"
    - alert: zpool_low_space
    expr: "zfs_zpool_free / zfs_zpool_size * 100 <= 10"
    labels:
        severity: medium
    annotations:
        summary: "Free space is at {{ .Value }}% for zpool: {{$labels.name}} on node: {{$labels.node}}"
        description: "Free space is at {{ .Value }}% for zpool: {{$labels.name}} on node: {{$labels.node}}"
```

![Firing Alert](/img/firing-alert.png)

I'm very new to Prometheus and alertmanager but these alerts are a good start.

## Conclusion
Learning how to create exporters opens up a whole world of possibilities. I already know the next step I want to take with this exporter... The Proxmox API provides some great info about SMART diagnostics for all the disks in Proxmox, this would be another great place to monitor so I can go ahead and have drives ready for my server if any errors start to arise.
