kubectl create secret generic mysql-pass --from-literal=password=YOUR_PASSWORD

kubectl create secret generic mysql1-pass --from-literal=password=root1234 --namespace=db

kubectl create secret generic mysql2-pass --from-literal=password=user1234 --namespace=db



# echo -n pass1234 | base64
# kubectl create -f - <<EOF
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


kubectl run mysql-client --image=mysql:5.7 -it --rm --restart=Never --namespace db -- mysql -h mysql-set1-0.mysqlset1 -u root -p
kubectl run mysql-client3 --image=mysql:5.7 -it --rm --restart=Never --namespace db -- mysql -h mysql-set2-0.mysqlset2 -u root -p


create table book(id int(11),name varchar(45),price float);
insert into book values(1,"book1",10.1);
insert into book values(2,"book2",9.1);


CREATE TABLE IF NOT EXISTS `mysql`.`books` (
  `id` INT NOT NULL,
  `name` VARCHAR(10) NULL,
  `code` VARCHAR(4) NULL,
  PRIMARY KEY (`id`));


CREATE TABLE IF NOT EXISTS `mysql`.`orders` (
  `id` INT NOT NULL,
  `orderNo` VARCHAR(9) NOT NULL,
  `status` CHAR(1) NOT NULL,
  PRIMARY KEY (`id`));


insert into books values(1,"book1","A001");
insert into books values(2,"book2","A002");
insert into books values(3,"book3","A003");

# 需要增加ColumnList
insert into orders(`id`,`orderNo`,`status`) values(1,"00001",'0');
insert into orders(`id`,`orderNo`,`status`) values(2,"00002",'1');
insert into orders(`id`,`orderNo`,`status`) values(3,"00003",'0');


