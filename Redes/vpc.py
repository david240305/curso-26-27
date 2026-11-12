import boto3


def crear_vpc():
  ec2 = boto3.client('ec2')

  # Se mantiene tu bloque CIDR original
  vpc = ec2.create_vpc(CidrBlock='193.168.5.0/16')
  vpc_id = vpc['Vpc']['VpcId']
  print(f'VPC creada con ID: {vpc_id}')

  ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={'Value': True})
  ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={'Value': True})

  # --- AQUÍ ESTÁ EL CAMBIO: Clave 'tipo' y valor 'prueba' ---
  ec2.create_tags(
      Resources=[vpc_id],
      Tags=[
          {'Key': 'Name', 'Value': 'MiVPC-Boto3'},
          {'Key': 'tipo', 'Value': 'prueba'},
      ],
  )

  # --- Crear e Internet Gateway (IGW) ---
  igw = ec2.create_internet_gateway()
  igw_id = igw['InternetGateway']['InternetGatewayId']
  ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
  ec2.create_tags(
      Resources=[igw_id], Tags=[{'Key': 'Name', 'Value': 'MiIGW-Boto3'}]
  )
  print(f'Internet Gateway creado y adjuntado: {igw_id}')

  # --- Crear Tabla de enrutamiento y apuntarla al IGW ---
  route_table = ec2.create_route_table(VpcId=vpc_id)
  route_table_id = route_table['RouteTable']['RouteTableId']
  ec2.create_route(
      RouteTableId=route_table_id,
      DestinationCidrBlock='0.0.0.0/0',
      GatewayId=igw_id,
  )
  ec2.create_tags(
      Resources=[route_table_id],
      Tags=[{'Key': 'Name', 'Value': 'MiTablaRuteo-Boto3'}],
  )
  print(f'Tabla de enrutamiento configurada hacia el IGW: {route_table_id}')

  return ec2, vpc_id, route_table_id


def crear_subred(ec2, vpc_id, route_table_id):
  subnet = ec2.create_subnet(
      VpcId=vpc_id, CidrBlock='193.168.5.0/24', AvailabilityZone='us-east-1a'
  )
  subnet_id = subnet['Subnet']['SubnetId']
  print(f'Subred creada con ID: {subnet_id}')

  ec2.create_tags(
      Resources=[subnet_id], Tags=[{'Key': 'Name', 'Value': 'MiSubred-Boto3'}]
  )

  # --- Asociar la tabla de enrutamiento a la subred ---
  ec2.associate_route_table(RouteTableId=route_table_id, SubnetId=subnet_id)

  # --- Auto-asignar IPs públicas al lanzar instancias ---
  ec2.modify_subnet_attribute(
      SubnetId=subnet_id, MapPublicIpOnLaunch={'Value': True}
  )
  print(f'Tabla de enrutamiento asociada a la subred {subnet_id}')

  return subnet_id


def crear_security_group(ec2, vpc_id):
  sg = ec2.create_security_group(
      GroupName='SG-Acceso-SSH',
      Description='Permitir trafico SSH desde el exterior',
      VpcId=vpc_id,
  )
  sg_id = sg['GroupId']

  ec2.authorize_security_group_ingress(
      GroupId=sg_id,
      IpPermissions=[{
          'IpProtocol': 'tcp',
          'FromPort': 22,
          'ToPort': 22,
          'IpRanges': [{
              'CidrIp': '0.0.0.0/0',
              'Description': 'SSH publico',
          }],
      }],
  )
  print(f'Security Group creado con ID: {sg_id} (Puerto 22 abierto)')
  return sg_id


def crear_instancia_ec2(ec2, subnet_id, sg_id):
  imagen_ami = 'ami-0c7217cdde317cfec'

  response = ec2.run_instances(
      ImageId=imagen_ami,
      InstanceType='t3.micro',
      SubnetId=subnet_id,
      SecurityGroupIds=[sg_id],
      KeyName='vockey',
      MinCount=1,
      MaxCount=1,
      TagSpecifications=[{
          'ResourceType': 'instance',
          'Tags': [{'Key': 'Name', 'Value': 'MiInstancia-Boto3'}],
      }],
  )

  instancia_id = response['Instances'][0]['InstanceId']
  print(f'Instancia EC2 creada con ID: {instancia_id}')
  return instancia_id


if __name__ == '__main__':
  ec2_client, vpc_id, route_table_id = crear_vpc()
  subnet_id = crear_subred(ec2_client, vpc_id, route_table_id)
  sg_id = crear_security_group(ec2_client, vpc_id)
  instancia_id = crear_instancia_ec2(ec2_client, subnet_id, sg_id)
  print(f'Despliegue finalizado. Instancia {instancia_id} creada.')