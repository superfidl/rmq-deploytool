# see deploy-node1.ps1 notes
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -JoinCluster `
  -NodeRole 2 `
  -Node1Host 'server1' `
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


