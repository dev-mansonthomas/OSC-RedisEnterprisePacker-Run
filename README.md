# Redis Enterprise - Run on Outscale

This project run Outscale AMIs for Redis Enterprise using [Packer](https://www.packer.io/) and automates the setup and teardown of the required Outscale infrastructure.


## Requirements

- [Outscale CLI](https://github.com/outscale/oapi-cli) 
- Outscale Account
- [jq](https://stedolan.github.io/jq/) (for parsing JSON in shell scripts)
- Bash shell (tested on Linux/macOS)
- Registered SSH key pair (for SSH access)
- A DNS server and Domain Name where you can customize DNS entries (Add IN NS statements)
- Tested with BASH 5.x/ZSH

## Initial Setup

### Install Packer

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/packer
```

### Outscale Setup

1. **OSC-CLI installation**

If you're using Homebrew : 

```sh
brew tap outscale/tap
brew install outscale/tap/oapi-cli
```
or check other installation methods here : [Github OAPI-CLI](https://github.com/outscale/oapi-cli) 

2. **Authentication Configuration**

Create a new Access Key ID in [Outscale Cockpit](https://cockpit.outscale.com/#/accesskeys)
or Click on your username in the upper right corner of the screen and then click on Access Key.

Add the following keys and values in your shell profile for packer

```sh
export OSC_ACCESS_KEY=...
export OSC_SECRET_KEY=...
```

and create `~/.osc/config.json`file with the following content :

```json
{
  "default": {
    "access_key": "ACCESSKEY",
    "secret_key": "SECRETKEY",
    "region": "eu-west-2"
  }
}
```

Validate that the authentication works by executing the "list VM" call : 

```sh
oapi-cli ReadVms
```

it should answer something similar to : 
```json
{
  "ResponseContext":{
    "RequestId":"a79c959b-c6c0-4087-b687-6b20f2dfc1a5"
  },
  "Vms":[]
}
```

3. **Generate a SSH key pair for outscale**

```sh
oapi-cli --profile default CreateKeypair \
  --KeypairName "outscale-tmanson-keypair"
```

```json
{
  "ResponseContext": {
    "RequestId": "0475ca1e-d0c5-441d-712a-da55a4175157"
  },
  "Keypair": {
    "PrivateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----",
    "KeypairType": "ssh-rsa",
    "KeypairName": "outscale-tmanson-keypair",
    "KeypairId": "key-abcdef1234567890abcdef1234567890",
    "KeypairFingerprint": "11:22:33:44:55:66:77:88:99:00:aa:bb:cc:dd:ee:ff"
  }
}
```

Save the `PrivateKey` value in a file `~/.ssh/outscale-tmanson-keypair.rsa` and `chmod 600 ~/.ssh/outscale-tmanson-keypair.rsa`

Replace the \n by linefeed.

In vi you can do this with 

```
:%s/\\n/\r/g
```

4. **Choose your Redis Cluster FQDN**

  Let's say you own `paquerette.com` domain, and want to use `outscale.paquerette.com` for the Redis Cluster

Add the following line
`CLUSTER_DNS=aws.paquerette.com`
to 
`_my_env.sh`



Update `_my_env.sh` with (copy the `_my_env_.sh_template` file)
 * `OWNER`       : Who is owner of the AWS VPC, this will be set in as VPC name and in tag, used by `aws-setup.sh`, ex: `OWNER="thomas-manson"`
 * `REGION`      : Which Region will Redis Enteprise be deployed by `my_instanciate.sh`, ex `REGION=eu-west-3`
 * `REDIS_LOGIN` : Redis Enterprise administrator login,    used by `my_instanciate.sh`, ex `REDIS_LOGIN=adm@redis.io`
 * `REDIS_PWD`   : Redis Enterprise administrator password, used by `my_instanciate.sh`, ex `REDIS_PWD=redis_adm`
 * `FLEX_FLAG`   : Set to "flex" to enable Flex Support, or "" if you want to disable it. Flex allows to use SSD for the DB available memory (at lower costs)
 * `FLEX_SIZE_GB`: Flex Disk Size in GB (2 disks are mounted in RAID0, so you'll get 2x this size as usable disk)
 * `FLEX_IOPS`   : IOPS per volume for io1 (min 100, max 64000 for AWS, 20000 for outscale, ratio 50 IOPS/GB) 
 * `MACHINE_TYPE`: Redis Node machine Type
 * `SSH_KEY`     : Path to the RSA Private Key


## Usage

Note: if you run multiple time `aws-setup.sh` / `teardown-aws-vpc.sh` / `build_and_deploy_image_with_packer.sh`, remove from `_my_env.sh` the generated values.
If you only rerun `aws-setup.sh` without rebuilding the AMI, keep the `AMI_ID` in the `_my_env.sh`

0. **Ensure your _my_env.sh has all required variables set**

```sh
REDIS_LOGIN=adm@redis.io
REDIS_PWD=redis_adm
OWNER="thomas-manson"
KEY_NAME=tmanson-aws-key
CLUSTER_DNS=aws.paquerette.com #for AWS
REGION=eu-west-3 # for AWS
#for outscale
OUTSCALE_CLUSTER_DNS=outscale.paquerette.com
OUTSCALE_REGION=eu-west-2
OUTSCALE_SSH_KEY="$HOME/.ssh/outscale-tmanson-keypair.rsa"
```

Run the following scripts in order from the project root:

1. **Provision the Infrastructure:**

   ```sh
   cd osc/
   ./osc-setup.sh
   ```

   This will append the following variables to `_my_env.sh` with the various IDs generated during the setup of the VPC.

   If your infrastructure is already in place, you can just fill up those variables.
   The mandatory ones are the AZ*, SUBNET*, SG_ID (Security Group)

   The other variables are used by the tear_down_outscale.sh script to delete all VMs & objets after you're finish testing.

   ```sh
   NET_ID=vpc-xxx
   IGW_ID=igw-xxx
   RTB_ID=rtb-xxx
   SG_ID=sg-xxx
   SUBNET1=subnet-xxx
   SUBNET2=subnet-xxx
   SUBNET3=subnet-xxx
   AZ1=eu-west-3a
   AZ2=eu-west-3b
   AZ3=eu-west-3c
   ```


2. **Instantiate an EC2 Instance from the Redis Enterprise Packer Image:**

  Choose if you want to use Flex or not.
  Flex is a technology that allow a Database to use RAM + SSD, without any impact on client code.
  To use flex, edit the my_instanciate*.sh and edit the following vars: 

```sh
FLEX_FLAG="flex" #set to "" if you don't want flex
FLEX_SIZE_GB="20" #2 disks are mounted in RAID0, so you'll get 2x$FLEX_SIZE_GB as usable disk
FLEX_IOPS="${FLEX_IOPS:-1000}"  # IOPS per volume for io1 (min 100, max 64000 for AWS, 20000 for outscale, ratio 50 IOPS/GB) 
```

   ```sh
   cd osc/
   my_instanciate_outscale.sh
   ```

   This will append the following variables to `_my_env.sh` with the various IDs generated during the setup of the VPC
   ```sh
   OUTSCALE_INSTANCE_PUBLIC_IP_1=13.38.11.137 #i-0f3731bccbefe8256
   OUTSCALE_INSTANCE_PUBLIC_IP_2=51.44.42.52 #i-0570bff1ec77d91bf
   OUTSCALE_INSTANCE_PUBLIC_IP_3=51.44.4.244 #i-0fe563086da4d41df
   ```

3. **Configure your DNS Zone**

  Edit your DNS zone with the output of the script my_instaciate.sh / my_instanciate_outscale.sh

example : 
```
###############################################################################################
ns1.outscale.paquerette.com. 10800 IN A 171.33.65.166
ns2.outscale.paquerette.com. 10800 IN A 171.33.82.31
ns3.outscale.paquerette.com. 10800 IN A 171.33.83.16

outscale.paquerette.com. 10800 IN A 171.33.65.166
outscale.paquerette.com. 10800 IN A 171.33.82.31
outscale.paquerette.com. 10800 IN A 171.33.83.16

outscale.paquerette.com. 10800 IN NS ns1.outscale.paquerette.com.
outscale.paquerette.com. 10800 IN NS ns2.outscale.paquerette.com.
outscale.paquerette.com. 10800 IN NS ns3.outscale.paquerette.com.
###############################################################################################

Cluster setup complete. Access your cluster at https://outscale.paquerette.com:8443 with username adm@redis.io and password redis_adm.
```

If you don't want to wait for DNS propagation, you can flush your local DNS cache with : 

On MacOsX : 
`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`

or 

On Linux:
`sudo resolvectl flush-caches`

5. **Connect to the Redis Cluster Manager:**

  After having configured the DNS zone, click on the URL displayed at the end of the my_instanciate*.sh script, enter the login & password.
  
  Check the Cluster Tab, and Nodes Tab to see that all 3 nodes are there.
  Then create a simple DB and test that you can connect to it using the generated FQDN (ex: redis-12000.outscale.paquerette.com:12000 for a DB using port 12000)


6. **Connect to Your Instance:**

   ```sh
   cd osc/
   connect_to_my_instance.sh 1
   ```

   (Replace `1` with the subnet index if needed.)

## Teardown

When finished, destroy all created AWS resources:

```sh
cd osc/
teardown-aws-vpc.sh
```

## Notes

- The project uses [`packer/ubuntu_ufw_aws_image.pkr.hcl`](packer/ubuntu_ufw_aws_image.pkr.hcl ) as the Packer template.
- Redis Enterprise tarball must be present in [`redis-software`](redis-software ). You can download it from [`Redis Cloud`](https://cloud.redis.io)
- Environment variables for resource IDs are stored in `_my_env.sh`.

## TODO
* Ajout de la license