#!/bin/sh
# Runs INSIDE the node container (see ../run-compat.sh): check.sh <angular_version> <library_tarball>
set -e
VERSION=$1
TARBALL=$2

# Exactly the packages a real consumer installs; typescript / rxjs / tslib are left to npm's
# peer-dependency resolution so each major gets the toolchain it declares. No --legacy-peer-deps:
# a library peer range that excludes this major must fail right here.
npm install --no-audit --no-fund --loglevel=error \
  "@angular/core@$VERSION" "@angular/common@$VERSION" "@angular/compiler@$VERSION" \
  "@angular/platform-browser@$VERSION" "@angular/compiler-cli@$VERSION" "@angular/build@$VERSION" "@angular/cli@$VERSION" \
  "@ngx-grpc/common@>=3.1.2" "@ngx-grpc/core@>=3.1.2" \
  "@ngx-grpc/well-known-types@>=3.1.2" "google-protobuf@^3.21.4" "@types/google-protobuf@^3.15.12" \
  "$TARBALL"

PACKAGE_NAME="$(tar -xOzf "$TARBALL" package/package.json | node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).name')"
for dep in @angular/core @angular/compiler-cli typescript rxjs @ngx-grpc/core "$PACKAGE_NAME"; do
  printf '  %s@%s\n' "$dep" "$(node -p "require('$dep/package.json').version")"
done
printf "export * from '%s';\n" "$PACKAGE_NAME" >src/lib-under-test.ts

echo "--- AOT production build (linker + type check of the shipped .d.ts)"
npx --no-install ng build --configuration production

echo "--- runtime check (JIT)"
node runtime-check.mjs "$PACKAGE_NAME" "$VERSION"

if [ -f extra-check.mjs ]; then
  echo "--- library-specific assertions"
  node extra-check.mjs "$PACKAGE_NAME"
fi
