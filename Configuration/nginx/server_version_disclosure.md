# Nginx Server Version & Banner Suppression

## 1. Overview
- **Vulnerability:** Server Version / Technology Disclosure (CWE-200 / OWASP A05)
- **Objective:** Suppress or rewrite server signatures to prevent technology fingerprinting.
- These steps are for **NGinx version 1.24** mainline **ubuntu version 24** not for the NGinx stable version.
- As long **ubuntu 24** is being used there is no need for upgrade to **version 1.29 or 1.30** later
---

## 2. Quick Decision Matrix

| Goal | Directive | Extra Packages? | Result Header | Compliance |
| :--- | :--- | :--- | :--- | :--- |
| **Hide Version Only** | `server_tokens off;` | No (Built-in) | `Server: nginx` | Resolves CWE-200 |
| **Mask Banner** | `more_set_headers 'Server: <NAME>';` | Yes (`headers-more`) | `Server: <NAME>` | Blocks generic fingerprinting |
| **Strip Header** | `more_clear_headers 'Server';` | Yes (`headers-more`) | *(No Server header)* | Full suppression |

---

## 3. Implementation Methods

### Method A: Native Version Suppression (Standard Fix)
*Hides the version numbers without installing external packages.*

Add or comment out the **server_tokens off** on the nginx.conf file.

### 1. Add or verify inside the http { ... } block:

Path:`sudo nano /etc/nginx/nginx.conf`
```NGinx
http {
    ...
    server_tokens off;
    ...
}
```

### 2. Test and reload:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

The output shows **server : nginx** without the version

## Method B: Ubuntu 24.04 Stock Nginx (1.24) — Complete Removal

Works with Ubuntu's default repository package.

### 1. Install module:
```bash
sudo apt update
sudo apt install -y libnginx-mod-http-headers-more-filter
```

### 2. Add to **/etc/nginx/nginx.conf** inside http { ... }:
```NGinx
http {
    ...
    server_tokens off;
    more_clear_headers 'Server';
    # Or mask: more_set_headers 'Server: APP_GATEWAY';
    ...
}
```

### 3. Test and reload:
```bash
sudo nginx -t && sudo systemctl reload nginx
```
## Method C: Official Nginx Repo (1.30+) — ABI Mismatch Workarounds
Use if **apt install libnginx-mod-http-headers-more-filter** fails due to **nginx-abi** conflicts.

## Option 1: Edge Proxy Removal (Cloudflare / ALB / HAProxy)
Cloudflare: **Rules → Transform Rules → Modify Response Header → Remove Server**.

HAProxy: Add http-response del-header Server to frontend/backend configuration.

## Option 2: Build Dynamic Module

## 1. Install build dependencies
```bash
sudo apt install -y build-essential libpcre2-dev zlib1g-dev libssl-dev git
```
## 2. Match exact running version
```bash
NGINX_VER=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+')
```
## 3. Download source and module
```bash
cd /tmp
wget [http://nginx.org/download/nginx-$](http://nginx.org/download/nginx-$){NGINX_VER}.tar.gz
tar -zxvf nginx-${NGINX_VER}.tar.gz
git clone [https://github.com/openresty/headers-more-nginx-module.git](https://github.com/openresty/headers-more-nginx-module.git)
```
## 4. Compile dynamic module
```bash
cd nginx-${NGINX_VER}
./configure --with-compat --add-dynamic-module=../headers-more-nginx-module
make modules
```
## 5. Copy and enable module
```bash
sudo mkdir -p /etc/nginx/modules
sudo cp objs/ngx_http_headers_more_filter_module.so /etc/nginx/modules/
```
**Add at the very top of /etc/nginx/nginx.conf:**
```NGinx
load_module /etc/nginx/modules/ngx_http_headers_more_filter_module.so;
```
**Inside http { ... }:**
```NGinx
more_clear_headers 'Server';
```

**Reload:**
```bash
sudo nginx -t && sudo systemctl reload nginx
```

## 4. Verification & Audit Evidence
**Run check:**
```bash
curl -I https://<your-domain>/
```

Verification Criteria
Version Fix: Header reads Server: nginx.

Masked Header: Header reads Server: <CUSTOM_IDENTIFIER>.

Cleared Header: Server: header line is absent.

Auditor Closure Note Template
"Remediation complete for CWE-200. Web server version tokens have been suppressed via server_tokens off; and the server signature has been stripped/masked at the reverse proxy layer. Technology fingerprinting is completely disabled."