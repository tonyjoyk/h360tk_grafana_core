
cd ../../ci-tests
mkdir -p target
chmod -R 777 target

echo Cleaning docker
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker network prune -f



echo Starting docker and testing
docker compose up -d
docker wait ci-tests-tester-1
docker compose stop

docker compose up --timeout 0 --exit-code-from tester 
echo CI tests are done !
