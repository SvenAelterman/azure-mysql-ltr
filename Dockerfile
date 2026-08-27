FROM mysql:8.4

RUN microdnf install -y curl tar gzip && \
    curl -L https://aka.ms/downloadazcopy-v10-linux -o /tmp/azcopy.tar.gz && \
    tar -xzf /tmp/azcopy.tar.gz -C /tmp && \
    mv /tmp/azcopy_linux_amd64_*/azcopy /usr/local/bin/azcopy && \
    chmod +x /usr/local/bin/azcopy && \
    microdnf clean all && \
    rm -rf /tmp/azcopy*

COPY backup-and-upload.sh /usr/local/bin/backup-and-upload.sh

CMD ["/usr/local/bin/backup-and-upload.sh"]
