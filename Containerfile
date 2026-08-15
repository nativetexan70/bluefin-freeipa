# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image
FROM ghcr.io/ublue-os/bluefin:stable

## Other possible base images include:
# FROM ghcr.io/ublue-os/bluefin:stable          (GNOME variant)
# FROM ghcr.io/ublue-os/bluefin-dx:stable       (GNOME developer experience variant)
#
# Universal Blue Images: https://github.com/orgs/ublue-os/packages

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.
##
## /run is tmpfs-mounted for the same reason /tmp already is: without it, package
## scriptlets that write runtime-only scratch state during install (e.g.
## certmonger, dnf, selinux-policy all drop files under /run as a side effect of
## the package transaction below) get that content baked permanently into the
## image layer, since there's no running init here to treat /run as ephemeral
## the way a real boot does. `bootc container lint`'s nonempty-run-tmp check
## flags exactly this. Mounting /run as tmpfs for the RUN step discards
## anything written there once the step completes, the same way the existing
## /tmp mount already does — nothing in build_files/ reads /run afterward, so
## nothing here depends on that content surviving into the image.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=tmpfs,dst=/run \
    bash /ctx/build.sh

# COPY writes directly to the image layer and is not subject to the bind-mount
# that the OCI runtime places on /etc/hostname during RUN steps. This ships an
# empty /etc/hostname so bootc has no upstream value to merge against, preventing
# it from ever overwriting the locally configured hostname (required for FreeIPA).
COPY --from=ctx /hostname /etc/hostname
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
