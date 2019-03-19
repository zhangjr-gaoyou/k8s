## K8s应用平台搭建-mycat&mysql

#### 说明

> 本验证在minikube下进行，几乎没有考虑网络、存储方面的优化配置。   
> 本部署方案为，mycat+mysql（2+2），二个mysql主机，各自有一个slaver。  
> 具体脚本参见 [github代码](https://github.com/zhangjr-gaoyou/k8s-mysql)

#### 配置

##### 1. mysql安装
> 这里安装mysqlset1 （1 master + 1 slaver），使用xtrabackup和 ncat做实时同步。

```
# 配置文件

apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql
  labels:
    app: mysql
data:
  master.cnf: |
    # Apply this config only on the master.
    [mysqld]
    log-bin
    log_bin_trust_function_creators=1
    lower_case_table_names=1
  slave.cnf: |
    # Apply this config only on slaves.
    [mysqld]
    super-read-only
    log_bin_trust_function_creators=1

```

```
# 配置密码

$ echo -n pass1234 | base64
$ kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mysql-user-pwd
  namespace: db
data:
  mysql-root-pwd: cGFzczEyMzQ=
  mysql-app-user-pwd: cGFzczEyMzQ=
  mysql-test-user-pwd: cGFzczEyMzQ=
EOF

```

```
# 创建mysqlset1服务。
# 这里必须首先创建服务，后续的statefulset依赖这个服务
# Headless service for stable DNS entries of StatefulSet members.
apiVersion: v1
kind: Service
metadata:
  name: mysqlset1
  labels:
    app: mysql-set1
spec:
  ports:
  - name: mysql
    port: 3306
  clusterIP: None
  selector:
    app: mysql-set1
---
# Client service for connecting to any MySQL instance for reads.
# For writes, you must instead connect to the master: mysql-0.mysql.
apiVersion: v1
kind: Service
metadata:
  name: mysqlset1-read
  labels:
    app: mysql-set1
spec:
  ports:
  - name: mysql
    port: 3306
  selector:
    app: mysql-set1

```


```
# 创建mysqlset statefulset

apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql-set1
  namespace: db
spec:
  selector:
    matchLabels:
      app: mysql-set1
  serviceName: mysqlset1
  replicas: 2
  template:
    metadata:
      labels:
        app: mysql-set1
    spec:
      imagePullSecrets:
      - name: myregistrykey
      initContainers:
      - name: init-mysql
        image: mysql:5.7
        command:
        - bash
        - "-c"
        - |
          set -ex
          # Generate mysql server-id from pod ordinal index.
          [[ `hostname` =~ -([0-9]+)$ ]] || exit 1
          ordinal=${BASH_REMATCH[1]}
          echo [mysqld] > /mnt/conf.d/server-id.cnf
          # Add an offset to avoid reserved server-id=0 value.
          echo server-id=$((100 + $ordinal)) >> /mnt/conf.d/server-id.cnf
          # Copy appropriate conf.d files from config-map to emptyDir.
          if [[ $ordinal -eq 0 ]]; then
            cp /mnt/config-map/master.cnf /mnt/conf.d/
          else
            cp /mnt/config-map/slave.cnf /mnt/conf.d/
          fi
        volumeMounts:
        - name: conf
          mountPath: /mnt/conf.d
        - name: config-map
          mountPath: /mnt/config-map
      - name: clone-mysql
        image: gcr.io/google-samples/xtrabackup:1.0
        command:
        - bash
        - "-c"
        - |
          set -ex
          # Skip the clone if data already exists.
          [[ -d /var/lib/mysql/mysql ]] && exit 0
          # Skip the clone on master (ordinal index 0).
          [[ `hostname` =~ -([0-9]+)$ ]] || exit 1
          ordinal=${BASH_REMATCH[1]}
          [[ $ordinal -eq 0 ]] && exit 0
          # Clone data from previous peer.
          ncat --recv-only mysql-set1-$(($ordinal-1)).mysqlset1 3307 | xbstream -x -C /var/lib/mysql
          # Prepare the backup.
          xtrabackup --prepare --target-dir=/var/lib/mysql
        volumeMounts:
        - name: datam1
          mountPath: /var/lib/mysql
          subPath: mysql
        - name: conf
          mountPath: /etc/mysql/conf.d
      containers:
      - name: mysql
        image: mysql:5.7
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-user-pwd
              key: mysql-root-pwd
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-user-pwd
              key: mysql-app-user-pwd
        - name: MYSQL_USER
          value: app
        ports:
        - name: mysql
          containerPort: 3306
        volumeMounts:
        - name: datam1
          mountPath: /var/lib/mysql
          subPath: mysql
        - name: conf
          mountPath: /etc/mysql/conf.d
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
        livenessProbe:
          exec:
           # command: ["mysqladmin", "ping"]
            command:
            - /bin/sh
            - "-c"
            - MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"
            - mysql -h 127.0.0.1 -u root -e "SELECT 1"
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          exec:
            # Check we can execute queries over TCP (skip-networking is off).
            #command: ["mysql", "-h", "127.0.0.1", "-e", "SELECT 1"]
            command:
            - /bin/sh
            - "-c"
            - MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"
            - mysql -h 127.0.0.1 -u root -e "SELECT 1"
          initialDelaySeconds: 5
          periodSeconds: 2
          timeoutSeconds: 1
      - name: xtrabackup
        image: gcr.io/google-samples/xtrabackup:1.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-user-pwd
              key: mysql-root-pwd
        ports:
        - name: xtrabackup
          containerPort: 3307
        command:
        - bash
        - "-c"
        - |
          set -ex
          cd /var/lib/mysql
          # Determine binlog position of cloned data, if any.
          if [[ -f xtrabackup_slave_info ]]; then
            # XtraBackup already generated a partial "CHANGE MASTER TO" query
            # because we're cloning from an existing slave.
            mv xtrabackup_slave_info change_master_to.sql.in
            # Ignore xtrabackup_binlog_info in this case (it's useless).
            rm -f xtrabackup_binlog_info
          elif [[ -f xtrabackup_binlog_info ]]; then
            # We're cloning directly from master. Parse binlog position.
            [[ `cat xtrabackup_binlog_info` =~ ^(.*?)[[:space:]]+(.*?)$ ]] || exit 1
            rm xtrabackup_binlog_info
            echo "CHANGE MASTER TO MASTER_LOG_FILE='${BASH_REMATCH[1]}',\
                  MASTER_LOG_POS=${BASH_REMATCH[2]}" > change_master_to.sql.in
          fi
          # Check if we need to complete a clone by starting replication.
          if [[ -f change_master_to.sql.in ]]; then
            echo "Waiting for mysqld to be ready (accepting connections)"
            until mysql -h 127.0.0.1 -uroot --password=${MYSQL_ROOT_PASSWORD}  -e "SELECT 1"; do sleep 1; done
            echo "Initializing replication from clone position"
            # In case of container restart, attempt this at-most-once.
            mv change_master_to.sql.in change_master_to.sql.orig
            echo "MASTER_PASSWORD='${MYSQL_ROOT_PASSWORD}'" > master_password
            mysql -h 127.0.0.1 -uroot --password=${MYSQL_ROOT_PASSWORD} <<EOF
          $(<change_master_to.sql.orig),
            MASTER_HOST='mysql-set1-0.mysqlset1',
            MASTER_USER='root',
          $(<master_password),
            MASTER_CONNECT_RETRY=10;
          START SLAVE;
          EOF
          fi
          # Start a server to send backups when requested by peers.
          exec ncat --listen --keep-open --send-only --max-conns=1 3307 -c \
            "xtrabackup --backup --slave-info --stream=xbstream --host=127.0.0.1 --user=root --password=$MYSQL_ROOT_PASSWORD"
        volumeMounts:
        - name: datam1
          mountPath: /var/lib/mysql
          subPath: mysql
        - name: conf
          mountPath: /etc/mysql/conf.d
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
      volumes:
      - name: conf
        emptyDir: {}
      - name: config-map
        configMap:
          name: mysql
  volumeClaimTemplates:
  - metadata:
      name: datam1
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi

```

通过dashboard可以查看状态。

同样的方式创建mysqlset2

```
# 验证方法

$ kubectl run mysql-client --image=mysql:5.7 -it --rm --restart=Never --namespace db -- mysql -h mysql-set1-0.mysqlset1 -u root -p
$ kubectl run mysql-client3 --image=mysql:5.7 -it --rm --restart=Never --namespace db -- mysql -h mysql-set2-0.mysqlset2 -u root -p

# 使用mysql数据库，建表insert数据进行查看
mysql> create table book(id int(11),name varchar(45),price float);
mysql> insert into book values(1,"book1",10.1);
mysql> insert into book values(2,"book2",9.1);

```


##### 2. mycat安装

```
# mycat镜像准备

FROM centos:7
USER root

# install java

ENV JAVA_VERSION=8 \
    JAVA_UPDATE=201 \
    JAVA_BUILD=09 \
    JAVA_PATH=42970487e3af4f5aa5bca3f542482c60 \
    JAVA_HOME="/usr/lib/jvm/default-jvm"

RUN yum install -y wget ca-certificates unzip && \
    cd "/tmp" && \
    wget --header "Cookie: oraclelicense=accept-securebackup-cookie;" \
        "http://download.oracle.com/otn-pub/java/jdk/${JAVA_VERSION}u${JAVA_UPDATE}-b${JAVA_BUILD}/${JAVA_PATH}/jdk-${JAVA_VERSION}u${JAVA_UPDATE}-linux-x64.tar.gz" && \
    tar -xzf "jdk-${JAVA_VERSION}u${JAVA_UPDATE}-linux-x64.tar.gz" && \
    mkdir -p "/usr/lib/jvm" && \
    mv "/tmp/jdk1.${JAVA_VERSION}.0_${JAVA_UPDATE}" "/usr/lib/jvm/java-${JAVA_VERSION}-oracle" && \
    ln -s "java-${JAVA_VERSION}-oracle" "$JAVA_HOME" && \
    ln -s "$JAVA_HOME/bin/"* "/usr/bin/" && \
    rm -rf "$JAVA_HOME/"*src.zip && \
    wget --header "Cookie: oraclelicense=accept-securebackup-cookie;" \
        "http://download.oracle.com/otn-pub/java/jce/${JAVA_VERSION}/jce_policy-${JAVA_VERSION}.zip" && \
    unzip -jo -d "${JAVA_HOME}/jre/lib/security" "jce_policy-${JAVA_VERSION}.zip" && \
    rm -f "${JAVA_HOME}/jre/lib/security/README.txt"

# install tini

ENV TINI_VERSION 0.14.0
ENV TINI_SHA 6c41ec7d33e857d4779f14d9c74924cab0c7973485d2972419a3b7c7620ff5fd

# Use tini as subreaper in Docker container to adopt zombie processes
RUN curl -fsSL https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-amd64 -o /bin/tini && chmod +x /bin/tini \
  && echo "$TINI_SHA  /bin/tini" | sha256sum -c -


# install mycat

RUN cd "/tmp" && \
    wget http://dl.mycat.io/1.6-RELEASE/Mycat-server-1.6-RELEASE-20161028204710-linux.tar.gz && \
    tar -xzf "Mycat-server-1.6-RELEASE-20161028204710-linux.tar.gz" && \
    mv /tmp/mycat /opt/mycat


VOLUME /opt/mycat/conf
EXPOSE 8066 9066

# run mycat
# ENTRYPOINT ["/bin/tini", "--"]
CMD ["/opt/mycat/bin/mycat", "console"]

```

```
# 生成 docker image
docker build -f ./Dockerfile.mycat -t mycat:1.7 .
# 你可以push到你的私有库，或者修改使用更轻量的base images

```

```
# 生成mycat配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: mycat
  namespace: db
  labels:
    app: mycat
data:
  server.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE mycat:server SYSTEM "server.dtd">
    <mycat:server xmlns:mycat="http://io.mycat/">
      <system>
        <property name="defaultSqlParser">druidparser</property>
        <property name="useGlobleTableCheck">0</property>  <!-- 1为开启全加班一致性检测、0为关闭 -->
      </system>
      <user name="root">
        <property name="password">pass1234</property>
        <property name="schemas">TESTDB</property>
      </user>
    </mycat:server>
  schema.xml: |
    <?xml version="1.0"?>
    <!DOCTYPE mycat:schema SYSTEM "schema.dtd">
    <mycat:schema xmlns:mycat="http://io.mycat/">
     <schema name="TESTDB" checkSQLschema="false" sqlMaxLimit="100">
        <table name="orders" dataNode="dn1,dn2" rule="mod-long" />
        <table name="books" primaryKey="id" type="global" dataNode="dn1,dn2" />
      </schema>
      <dataNode name="dn1" dataHost="mysql-set1" database="mysql" />
      <dataNode name="dn2" dataHost="mysql-set2" database="mysql" />
      <dataHost name="mysql-set1" maxCon="1000" minCon="10" balance="0"
        writeType="0" dbType="mysql" dbDriver="native" switchType="1"  slaveThreshold="100">
        <heartbeat>select user()</heartbeat>
        <writeHost host="mysql-set1-0.myset1" url="mysql-set1-0.mysqlset1:3306" user="root"
          password="pass1234">
        </writeHost>
      </dataHost>
      <dataHost name="mysql-set2" maxCon="1000" minCon="10" balance="0"
        writeType="0" dbType="mysql" dbDriver="native" switchType="1"  slaveThreshold="100">
        <heartbeat>select user()</heartbeat>
        <writeHost host="mysql-set2-0.myset2" url="mysql-set2-0.mysqlset2:3306" user="root"
          password="pass1234">
        </writeHost>
      </dataHost>
    </mycat:schema>
  rule.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE mycat:rule SYSTEM "rule.dtd">
    <mycat:rule xmlns:mycat="http://io.mycat/">
      <tableRule name="mod-long">
        <rule>
            <columns>id</columns>
            <algorithm>mod-long</algorithm>
        </rule>
      </tableRule>
      <function name="mod-long" class="io.mycat.route.function.PartitionByMod">
        <!-- how many data nodes -->
        <property name="count">2</property>
      </function>
    </mycat:rule>

```

```
# 部署mycat服务
kind: Service
apiVersion: v1
metadata:
  name: mycat-svc
  namespace: db
spec:
  type: NodePort
  selector:
    app: mycat
  ports:
  - name: data
    protocol: TCP
    port: 8066
  - name: admin
    protocol: TCP
    port: 9066
```

```
# 部署mycat deployment，这里由于资源问题，只使用了一个副本
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mycat-deployment
  namespace: db
  labels:
    app: mycat
spec:
  selector:
    matchLabels:
      app: mycat
  replicas: 1
  template:
    metadata:
      labels:
        app: mycat
    spec:
      imagePullSecrets:
      - name: myregistrykey
      initContainers:
      - name: init-mycat
        image: mycat:1.6
        command:
        - bash
        - "-c"
        - |
          set -ex
            cp -R /opt/mycat/conf/* /mnt/conf
            cp /mnt/config-map/server.xml /mnt/conf/
            cp /mnt/config-map/schema.xml /mnt/conf/
            cp /mnt/config-map/rule.xml /mnt/conf/
        volumeMounts:
        - mountPath: /mnt/config-map
          name: config-map
        - mountPath: /mnt/conf
          name: conf
      containers:
      - name: mycat
        image: mycat:1.6
        ports:
        - name: data
          containerPort: 8066
        - name: admin
          containerPort: 9066
        volumeMounts:
        - mountPath: /opt/mycat/conf
          name: conf
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
      volumes:
      - name: conf
        emptyDir: {}
      - name: config-map
        configMap:
          name: mycat

```

##### 3. 安装mycat-web

```
# Dockerfile

FROM centos:7
USER root

# install java

ENV JAVA_VERSION=8 \
    JAVA_UPDATE=201 \
    JAVA_BUILD=09 \
    JAVA_PATH=42970487e3af4f5aa5bca3f542482c60 \
    JAVA_HOME="/usr/lib/jvm/default-jvm"

RUN yum install -y wget ca-certificates unzip && \
    cd "/tmp" && \
    wget --header "Cookie: oraclelicense=accept-securebackup-cookie;" \
        "http://download.oracle.com/otn-pub/java/jdk/${JAVA_VERSION}u${JAVA_UPDATE}-b${JAVA_BUILD}/${JAVA_PATH}/jdk-${JAVA_VERSION}u${JAVA_UPDATE}-linux-x64.tar.gz" && \
    tar -xzf "jdk-${JAVA_VERSION}u${JAVA_UPDATE}-linux-x64.tar.gz" && \
    mkdir -p "/usr/lib/jvm" && \
    mv "/tmp/jdk1.${JAVA_VERSION}.0_${JAVA_UPDATE}" "/usr/lib/jvm/java-${JAVA_VERSION}-oracle" && \
    ln -s "java-${JAVA_VERSION}-oracle" "$JAVA_HOME" && \
    ln -s "$JAVA_HOME/bin/"* "/usr/bin/" && \
    rm -rf "$JAVA_HOME/"*src.zip && \
    wget --header "Cookie: oraclelicense=accept-securebackup-cookie;" \
        "http://download.oracle.com/otn-pub/java/jce/${JAVA_VERSION}/jce_policy-${JAVA_VERSION}.zip" && \
    unzip -jo -d "${JAVA_HOME}/jre/lib/security" "jce_policy-${JAVA_VERSION}.zip" && \
    rm -f "${JAVA_HOME}/jre/lib/security/README.txt"

# install tini

ENV TINI_VERSION 0.14.0
ENV TINI_SHA 6c41ec7d33e857d4779f14d9c74924cab0c7973485d2972419a3b7c7620ff5fd

# Use tini as subreaper in Docker container to adopt zombie processes
RUN curl -fsSL https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-amd64 -o /bin/tini && chmod +x /bin/tini \
  && echo "$TINI_SHA  /bin/tini" | sha256sum -c -


# install mycat-web
COPY startweb.sh /usr/bin

RUN cd "/tmp" && \
    wget http://dl.mycat.io/zookeeper-3.4.6.tar.gz && \
    tar -xzf "zookeeper-3.4.6.tar.gz" && \
    mv /tmp/zookeeper-3.4.6 /opt/zookeeper-3.4.6 && \
    cp /opt/zookeeper-3.4.6/conf/zoo_sample.cfg /opt/zookeeper-3.4.6/conf/zoo.cfg && \
    wget http://dl.mycat.io/mycat-web-1.0/Mycat-web-1.0-SNAPSHOT-20170102153329-linux.tar.gz && \
    tar -xzf "Mycat-web-1.0-SNAPSHOT-20170102153329-linux.tar.gz" && \
    mv /tmp/mycat-web /opt/mycat-web


EXPOSE 8082

# run mycat
ENTRYPOINT ["/bin/tini", "--"]
CMD ["/usr/bin/startweb.sh"]
#CMD /usr/bin/startweb.sh


```

```
# mycat-web 服务
kind: Service
apiVersion: v1
metadata:
  name: mycatweb-svc
  namespace: db
spec:
  type: NodePort
  selector:
    app: mycatweb
  ports:
  - protocol: TCP
    port: 8082

```

```
# mycat-web 部署
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mycatweb-deployment
  namespace: db
  labels:
    app: mycatweb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mycatweb
  template:
    metadata:
      labels:
        app: mycatweb
    spec:
      containers:
      - name: mycat-web
        image: mycat-web:1.0
        ports:
        - containerPort: 8082


```

> mycat 使用
> 查询mycat-web 的端口，在浏览器打开。如：http://172.16.93.248:31824/mycat    
> 缺省使用本机ZK（127.0.0.1）  
> 在mycat菜单（mycat服务管理中，新建mycat）配置信息：
> 名称：英文名称即可     
> IP地址：mycat-svc.db    
> 管理端口：9066    
> 服务端口：8066   
> 数据库：虚拟的数据库 TESTDB
> ....
> 
> 

```
# 验证
 $ kubectl run mysql-client2 --image=mysql:5.7 -i -t --rm --restart=Never --namespace db  -- mysql -h mycat-svc.db -u root -P8066 -p
 
# 这二个表已经分别在mysql-set1-0.mysqlset1 和 mysql-set2-0.mysqlset2 中创建。
mysql> insert into books values(1,"book1","A001");
mysql> insert into books values(2,"book2","A002");
mysql> insert into books values(3,"book3","A003");

# 需要增加ColumnList
mysql> insert into orders(`id`,`orderNo`,`status`) values(1,"00001",'0');
mysql> insert into orders(`id`,`orderNo`,`status`) values(2,"00002",'1');
mysql> insert into orders(`id`,`orderNo`,`status`) values(3,"00003",'0');

```  
