# Helm Chart for OAI New Radio User Equipment (OAI-NR-UE)

This helm-chart is only tested for [RF Simulated oai-nr-ue](https://gitlab.eurecom.fr/oai/openairinterface5g/-/blob/develop/radio/rfsimulator/README.md). You can read about the design of [oai-nr-ue](https://gitlab.eurecom.fr/oai/openairinterface5g/-/blob/develop/doc/nr-ue-design.md). You can use these charts with:
- USRP B2XX
- USRP N3XX
- USRP X3XX

**Note**: This chart is tested on [Minikube](https://minikube.sigs.k8s.io/docs/) and [Red Hat Openshift](https://www.redhat.com/fr/technologies/cloud-computing/openshift) 4.10, 4.12, 4.13 RFSIM requires minimum 2CPU and 2Gi RAM and [multus-cni](https://github.com/k8snetworkplumbingwg/multus-cni) plugin in case gNB is not in the same cluster. 
 
## Introduction

To know more about the feature set of OpenAirInterface you can check it [here](https://gitlab.eurecom.fr/oai/openairinterface5g/-/blob/develop/doc/FEATURE_SET.md#openairinterface-5g-nr-feature-set). 

The [codebase](https://gitlab.eurecom.fr/oai/openairinterface5g/-/tree/develop) for NR-UE is same as gNB, CU, DU, CU-CP/CU-UP. Everyweek on [docker-hub](https://hub.docker.com/r/oaisoftwarealliance/oai-gnb) our [Jenkins Platform](https://jenkins-oai.eurecom.fr/view/RAN/) publishes docker-images for `oaisoftwarealliance/oai-nr-ue` 

Each image has develop tag and a dedicated week tag for example `2023.w18`. We only publish Ubuntu 18.04/20.04 images. We do not publish RedHat/UBI images. These images you have to build from the source code on your RedHat systems or Openshift Platform. You can follow this [tutorial](../../../openshift/README.md) for that.

The helm chart of OAI-NR-UE creates multiples Kubernetes resources,

1. Service
2. Role Base Access Control (RBAC) (role and role bindings)
3. Deployment
4. Configmap
5. Service account
6. Network-attachment-defination (Optional only when multus is used)

The directory structure

```
.
├── Chart.yaml
├── templates
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── _helpers.tpl
│   ├── multus.yaml
│   ├── NOTES.txt
│   ├── rbac.yaml
│   ├── serviceaccount.yaml
│   └── service.yaml
└── values.yaml
```

## Parameters

[Values.yaml](./values.yaml) contains all the configurable parameters. Below table defines the configurable parameters. You need a dedicated interface for for NR-UE when it will run on a different cluster then gNB/DU.


|Parameter                       |Allowed Values                 |Remark                               |
|--------------------------------|-------------------------------|-------------------------------------|
|kubernetesType                  |Vanilla/Openshift              |Vanilla Kubernetes or Openshift      |
|nfimage.repository              |Image Name                     |                                     |
|nfimage.version                 |Image tag                      |                                     |
|nfimage.pullPolicy              |IfNotPresent or Never or Always|                                     |
|imagePullSecrets.name           |String                         |Good to use for docker hub           |
|serviceAccount.create           |true/false                     |                                     |
|serviceAccount.annotations      |String                         |                                     |
|serviceAccount.name             |String                         |                                     |
|podSecurityContext.runAsUser    |Integer (0,65534)              |                                     |
|podSecurityContext.runAsGroup   |Integer (0,65534)              |                                     |
|multus.n2Interface.create       |true/false                     |                                     |
|multus.n2Interface.Ipadd        |Ip-Address                     |                                     |
|multus.n2Interface.Netmask      |Netmask                        |                                     |
|multus.n2Interface.Gateway      |Ip-Address                     |                                     |
|multus.n2Interface.routes       |Json                           |Routes if you want to add in your pod|
|multus.n2Interface.hostInterface|host interface                 |Host interface on which pod will run |
|multus.defaultGateway           |Ip-Address                     |Default route inside pod             |


## Advanced Debugging Parameters

Only needed if you are doing advanced debugging

|Parameter                        |Allowed Values                 |Remark                                        |
|---------------------------------|-------------------------------|----------------------------------------------|
|start.nrue                      |true/false                     |If true nrue container will go in sleep mode   |
|start.tcpdump                    |true/false                     |If true tcpdump container will go in sleepmode|
|includeTcpDumpContainer          |true/false                     |If false no tcpdump container will be there   |
|tcpdumpimage.repository          |Image Name                     |                                              |
|tcpdumpimage.version             |Image tag                      |                                              |
|tcpdumpimage.pullPolicy          |IfNotPresent or Never or Always|                                              |
|persistent.sharedvolume          |true/false                     |Save the pcaps in a shared volume with NRF    |
|resources.define                 |true/false                     |                                              |
|resources.limits.tcpdump.cpu     |string                         |Unit m for milicpu or cpu                     |
|resources.limits.tcpdump.memory  |string                         |Unit Mi/Gi/MB/GB                              |
|resources.limits.nf.cpu          |string                         |Unit m for milicpu or cpu                     |
|resources.limits.nf.memory       |string                         |Unit Mi/Gi/MB/GB                              |
|resources.requests.tcpdump.cpu   |string                         |Unit m for milicpu or cpu                     |
|resources.requests.tcpdump.memory|string                         |Unit Mi/Gi/MB/GB                              |
|resources.requests.nf.cpu        |string                         |Unit m for milicpu or cpu                     |
|resources.requests.nf.memory     |string                         |Unit Mi/Gi/MB/GB                              |
|readinessProbe                   |true/false                     |default true                                  |
|livenessProbe                    |true/false                     |default false                                 |
|terminationGracePeriodSeconds    |5                              |In seconds (default 5)                        |
|nodeSelector                     |Node label                     |                                              |
|nodeName                         |Node Name                      |                                              |

## How to use

Make sure the core network is running else you need to first start the core network. You can follow any of the below links
  - [OAI 5G Core Basic](../../oai-5g-basic/README.md)
  - [OAI 5G Core Mini](../../oai-5g-mini/README.md)
  
Make sure the gNB is running in split mode or non-split mode.

1. If you are using nr-ue with multus interface then configure the gNB/DU ip-address or FQDN in `config.rfSimServer`.

```bash
helm install oai-nr-ue .
```

## BMW lab flow: UE attach to PNF (NFAPI) and validate ping/iperf to CN

This section is tailored for the BMW manifests in this repo:
- RAN PNF/VNF are deployed in namespace `oai`
- OAI CN is deployed in namespace `oai-cn`
- UE uses RFSim and connects to the PNF Service name (default `config.rfSimServer: "oai-pnf"`)

### 0) Set kubeconfig

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
```

### 1) Prerequisites

- `oai-pnf` and `oai-vnf` are Running in namespace `oai`
- OAI CN is Running in namespace `oai-cn`
- (Recommended) AMF NGAP Service exists: `oai-amf-ngap` in `oai-cn` exposing `38412/SCTP`

Quick checks:

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
kubectl get pods -n oai -o wide
kubectl get pods -n oai-cn -o wide
kubectl get svc -n oai-cn oai-amf-ngap -o wide || true
```

### 2) Install / upgrade UE

From `bmw-cicd-manifests/helm-charts/`:

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config

helm upgrade --install oai-nr-ue ./oai-nr-ue -n oai -f ./oai-nr-ue/values.yaml
kubectl rollout status -n oai deploy/oai-nr-ue
kubectl get pods -n oai -o wide | grep oai-nr-ue
```

### 3) Verify UE attaches to the PNF

Check UE logs for RFSim/attach progression (exact strings vary by image/version):

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
kubectl logs -n oai deploy/oai-nr-ue --tail=400
```

You can also confirm the UE created the tunnel interface (usually `oaitun_ue1`) inside the pod:

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
UE_POD="$(kubectl get pod -n oai -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n oai "$UE_POD" -- ip -br addr
kubectl exec -n oai "$UE_POD" -- ip link show oaitun_ue1 || true
```

### 4) Validate data plane (ping)

Once `oaitun_ue1` exists, run pings through it.

Examples (adjust IPs to your CN/UPF setup):

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
UE_POD="$(kubectl get pod -n oai -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"

# Example: ping UPF / N6 side gateway used in many OAI examples
kubectl exec -n oai "$UE_POD" -- ping -I oaitun_ue1 -c 3 12.1.1.1 || true

# Example: internet reachability (requires DN/NAT configured)
kubectl exec -n oai "$UE_POD" -- ping -I oaitun_ue1 -c 3 8.8.8.8 || true
```

### 5) Validate throughput (iperf3)

You need an iperf3 server reachable from the UE data network (behind the UPF).
Common options:
- Use an existing DN (if your lab provides one) and run `iperf3 -s` there
- Or deploy an iperf3 server as part of your DN/traffic steering setup

From the UE pod:

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
UE_POD="$(kubectl get pod -n oai -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"

# Replace <IPERF_SERVER_IP> with the server reachable through UPF
kubectl exec -n oai "$UE_POD" -- iperf3 -c <IPERF_SERVER_IP> -t 10 -i 1 || true
```

### Uninstall

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
helm uninstall oai-nr-ue -n oai
```

## Note

1. If you are using multus then make sure it is properly configured and if you don't have a gateway for your multus interface then avoid using gateway and defaultGateway parameter. Either comment them or leave them empty. Wrong gateway configuration can create issues with pod networking and pod will not be able to resolve service names.
