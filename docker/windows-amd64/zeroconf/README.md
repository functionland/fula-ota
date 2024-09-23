This is a simple zeroconf server to discover fxblox devices on teh same network

## Build
```
$env:GOOS = "windows"; $env:GOARCH = "amd64"; go build -o zeroconf_discovery.exe
```