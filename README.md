# alpine-linux-rg353vs-minimal
Minimal Alpine Linux port to Anbernic RG353VS using ROCKNIX kernel.

# Usage
```bash 
./build-minimal-alpine-rg353vs.sh [out.img]
```

```shell
gunzip -c alpine-rg353vs-minimal.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```
