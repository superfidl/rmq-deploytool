# the Clustername / Node1host config directive needs to be the same as your hostname this is mostly capital letters, 
# check after the first node install 'with rabbitmqctl eval "node()."' use that hostname in the same upper or lower case in the Node1host config directives,
# otherwise you cluster join will fail.
#
# second your certificate needs to be created with the "a wildcard or multiple sans it could be you windows CA needs crate a template so its allowed to use the "Microsoft RSA SChannel Cryptographic Provider" 
# if you are restricted and cannot select "Microsoft RSA SChannel Cryptographic Provider" then you cannot use the pfx extraction,from this script and need to supply the key,crt and ca seperately
# as "Microsoft RSA SChannel Cryptographic Provider" will only allow the  private key export with certutil and other default microsoft tool. if you are stuck at this then convert the template with openssl as a fallback..
#
# note: the CA root cert sometimes needs to be specified seperately as this is sometimes not extracted from the certificate due to a policy.
#
# the rabbitmq USER and password are the credentials from secret server site connector. these are the credentials that are used to validate secret server
# the rabbitmq ADMIN and password are the rabbitmq management userid and password. store them in a secret in secret server
# the ADMin credentials and other values are synced across the cluster
#
# IMPORTANT Operation Remark: 
# DO NOT turn off more then ONE hosts inside the cluster as it can only tolerate one node failure. it will bring down the app if two hosts are not functioning
# this is to remember when doing maintenance , patches and upgrade during operational hours.
# the loadbalancer will talk to only one noe at the time. it should never talk to multiple nodes.. also important
#
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -JoinCluster `
  -NodeRole 1 `
  -ClusterName 'server1' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'removed' `
  -RabbitMQUserPassword 'removed' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'removed' `
  -CertMode 2 `
  -RabbitMQPfxPath 'D:\Delivery\rmq-deploytool-main\certs\rabbitmq-cert.pfx' `
  -PfxPassword 'removed' `
  -ExternalCA 'D:\Delivery\rmq-deploytool-main\certs\ca.pem' `
  -ErlangCookieValue 'removed'


