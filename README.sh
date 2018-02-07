# Example are made to be run in GCE. Should be easy to move somewhere else.
############### Setup
## Create GCP infra

# Create project:
export REGION=us-east1
export ZONE="$REGION-b"
gcloud projects create --name matrix

# Create cluster:
gcloud container clusters create matrix-cluster \
    --zone $ZONE -m n1-standard-1 --disk-size 50 \
    --num-nodes 1 --addons ''

# Import cluster certificates:
gcloud container clusters get-credentials matrix-cluster --zone $ZONE
export CLUSTER=$(kubectl config get-clusters | grep matrix-cluster)

# Create our data persistent disk:
gcloud compute disks create matrix-data-pd --size 50 --zone $ZONE --type pd-standard

## Create nfs server for share data

gcloud compute disks create nfs-data-pd --size 1 --zone $ZONE --type pd-standard
kubectl create -f common/nfs.yaml --cluster $CLUSTER

# Mount and put config file on nfs

kubectl port-forward nfs-server-0 2049:2049 --cluster $CLUSTER &
mkdir /tmp/nfs
sudo mount localhost:/ /tmp/nfs

sudo cp homeserver.yaml /tmp/nfs/homeserver.yaml
sudo mkdir /tmp/nfs/irc
sudo cp irc-config.yaml /tmp/nfs/irc/config.yaml

sudo umount /tmp/nfs
kill %1

## Create postgresql database

## Create Synapse deployment

# Update config file:
vim common/config.yaml

# Create our synapse kubernetes componentes:
kubectl create -f common/config.yaml --cluster $CLUSTER
kubectl create -f synapse/synapse-service.yaml --cluster $CLUSTER
kubectl create -f synapse/synapse-statefulset.yaml --cluster $CLUSTER

## Create nginx reverse-proxy

# Create the static IP:
gcloud compute addresses create $matrix-cluster-ip --region $REGION --cluster $CLUSTER
export INGRESS_IP=$(gcloud compute addresses list | grep matrix-cluster-ip | awk '{print $3}')

# Assign to Compute Engine:
export LB_INSTANCE_NAME=$(kubectl describe nodes --cluster $CLUSTER | head -n1 | awk '{print $2}')
export LB_INSTANCE_NAT=$(gcloud compute instances describe $LB_INSTANCE_NAME | grep -A3 networkInterfaces: | tail -n1 | awk -F': ' '{print $2}')
gcloud compute instances delete-access-config $LB_INSTANCE_NAME \
  --access-config-name "$LB_INSTANCE_NAT"
gcloud compute instances add-access-config $LB_INSTANCE_NAME \
  --access-config-name "$LB_INSTANCE_NAT" --address $INGRESS_IP

# Assign role to the node:
kubectl label nodes $LB_INSTANCE_NAME role=load-balancer --cluster $CLUSTER

# Enable HTTP, HTTPS and 8448 on node:

gcloud compute instances add-tags $LB_INSTANCE_NAME --tags http-server,https-server,matrix-server
gcloud compute firewall-rules create matrix-federation --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:8448 --source-ranges=0.0.0.0/0 --target-tags=matrix-server

#Create the ingress controller:
kubectl create -f ingress/nginx-ingress-controller.yaml --cluster $CLUSTER

#Create the lego app for auto certificates renew:
kubectl create -f ingress/lego.yaml --cluster $CLUSTER

# Update the domains in the ingress file:
vim synapse/ingress.yaml

# Create the ingress:
kubectl create -f synapse/ingress.yaml --cluster $CLUSTER

## Install NFS server

gcloud compute disks create nfs-data-pd --size 1 --zone $ZONE --type pd-standard

## Install Bridges

kubectl create secret generic matrix_creds --from-literal="MATRIX_LOCALPART=$MATRIX_LOCALPART" --from-literal="MATRIX_PASSWORD=$MATRIX_PASSWORD"
kubectl create -f appservices/ --cluster $CLUSTER

## Register User

kubectl --cluster $CLUSTER exec -it matrix-0 -- register_new_matrix_user -c /data/homeserver.yaml https://localhost:8448
