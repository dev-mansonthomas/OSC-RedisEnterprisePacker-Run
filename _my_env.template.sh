# copy this file to _my_env.sh
OWNER="thomas-manson"
OUTSCALE_REGION=eu-west-2
OUTSCALE_SSH_KEY="$HOME/.ssh/outscale-tmanson-keypair.rsa"
# Redis Run Settings
REDIS_LOGIN=adm@redis.io
REDIS_PWD=redis_adm
OUTSCALE_CLUSTER_DNS=outscale.paquerette.com
OUTSCALE_REGION=eu-west-2
FLEX_FLAG="flex"                # "" to disable flex
FLEX_SIZE_GB="20"               # Flex Disk Size in GB (2 disks are mounted in RAID0, so you'll get 2x this size as usable disk)
FLEX_IOPS="${FLEX_IOPS:-1000}"  # IOPS per volume for io1 (min 100, max 64000 for AWS, 20000 for outscale, ratio 50 IOPS/GB) 
MACHINE_TYPE="tinav5.c2r4p3"
# OUTSCALE AMI ID
OUTSCALE_AMI_ID=