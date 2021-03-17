#Rebuilds all ondewo proto compiler docker images
cd angular
bash build.sh
cd ../js
bash build.sh
cd ../node
bash build.sh
cd ../typescript
bash build.sh