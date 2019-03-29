#bin/bash
/opt/zookeeper-3.4.6/bin/zkServer.sh start
cd /opt/mycat-web
echo "start mycat-web..."
./start.sh
echo "started!"
