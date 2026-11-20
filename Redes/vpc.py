import boto3


def crear_vpc():
  ec2 = boto3.client('ec2')

  # MODIFICADO: Cambiado a 192.168.0.0/16 (rango privado estándar RFC 1918)
  vpc = ec2.create_vpc(CidrBlock='192.168.0.0/16')
  vpc_id = vpc['Vpc']['VpcId']
  print(f'VPC creada con ID: {vpc_id}')

  ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={'Value': True})
  ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={'Value': True})

  ec2.create_tags(
      Resources=[vpc_id],
      Tags=[
          {'Key': 'Name', 'Value': 'MiVPC-Boto3'},
          {'Key': 'tipo', 'Value': 'prueba'},
      ],
  )

  # Internet Gateway (IGW)
  igw = ec2.create_internet_gateway()
  igw_id = igw['InternetGateway']['InternetGatewayId']
  ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
  ec2.create_tags(
      Resources=[igw_id], Tags=[{'Key': 'Name', 'Value': 'MiIGW-Boto3'}]
  )
  print(f'Internet Gateway creado y adjuntado: {igw_id}')

  # Tabla de enrutamiento PÚBLICA (apunta al IGW)
  route_table = ec2.create_route_table(VpcId=vpc_id)
  route_table_id = route_table['RouteTable']['RouteTableId']
  ec2.create_route(
      RouteTableId=route_table_id,
      DestinationCidrBlock='0.0.0.0/0',
      GatewayId=igw_id,
  )
  ec2.create_tags(
      Resources=[route_table_id],
      Tags=[{'Key': 'Name', 'Value': 'TablaRuteo-Publica-Boto3'}],
  )

  return ec2, vpc_id, route_table_id


def crear_subred_publica(ec2, vpc_id, route_table_id):
  # MODIFICADO: Rango dentro de 192.168.0.0/16
  subnet = ec2.create_subnet(
      VpcId=vpc_id, CidrBlock='192.168.1.0/24', AvailabilityZone='us-east-1a'
  )
  subnet_id = subnet['Subnet']['SubnetId']
  ec2.create_tags(
      Resources=[subnet_id],
      Tags=[{'Key': 'Name', 'Value': 'Subred-Publica-Boto3'}],
  )

  ec2.associate_route_table(RouteTableId=route_table_id, SubnetId=subnet_id)
  ec2.modify_subnet_attribute(
      SubnetId=subnet_id, MapPublicIpOnLaunch={'Value': True}
  )
  print(f'Subred PÚBLICA creada y configurada: {subnet_id}')

  return subnet_id


def crear_red_privada(ec2, vpc_id, subnet_publica_id):
  # 1. IP Elástica para el NAT Gateway
  eip = ec2.allocate_address(Domain='vpc')
  allocation_id = eip['AllocationId']

  # 2. NAT Gateway alojado en la SUBRED PÚBLICA
  nat_gw = ec2.create_nat_gateway(
      SubnetId=subnet_publica_id, AllocationId=allocation_id
  )
  nat_gw_id = nat_gw['NatGateway']['NatGatewayId']
  ec2.create_tags(
      Resources=[nat_gw_id], Tags=[{'Key': 'Name', 'Value': 'MiNAT-Boto3'}]
  )
  print(f'Creando NAT Gateway {nat_gw_id}... esperando disponibilidad (1-2 min).')

  waiter = ec2.get_waiter('nat_gateway_available')
  waiter.wait(NatGatewayIds=[nat_gw_id])
  print('NAT Gateway listo.')

  # 3. Subred PRIVADA
  subnet_priv = ec2.create_subnet(
      VpcId=vpc_id, CidrBlock='192.168.2.0/24', AvailabilityZone='us-east-1a'
  )
  subnet_priv_id = subnet_priv['Subnet']['SubnetId']
  ec2.create_tags(
      Resources=[subnet_priv_id],
      Tags=[{'Key': 'Name', 'Value': 'Subred-Privada-Boto3'}],
  )

  # 4. Tabla de enrutamiento PRIVADA (apunta al NAT Gateway)
  rt_priv = ec2.create_route_table(VpcId=vpc_id)
  rt_priv_id = rt_priv['RouteTable']['RouteTableId']
  ec2.create_route(
      RouteTableId=rt_priv_id,
      DestinationCidrBlock='0.0.0.0/0',
      NatGatewayId=nat_gw_id,
  )
  ec2.create_tags(
      Resources=[rt_priv_id],
      Tags=[{'Key': 'Name', 'Value': 'TablaRuteo-Privada-Boto3'}],
  )

  # 5. Asociar tabla privada a subred privada
  ec2.associate_route_table(RouteTableId=rt_priv_id, SubnetId=subnet_priv_id)
  print(f'Subred PRIVADA creada y enrutada al NAT: {subnet_priv_id}')

  return subnet_priv_id


def crear_security_groups(ec2, vpc_id):
  # SG 1: Público (acepta SSH desde internet)
  sg_pub = ec2.create_security_group(
      GroupName='SG-Publico-SSH',
      Description='Permitir trafico SSH desde el exterior',
      VpcId=vpc_id,
  )
  sg_pub_id = sg_pub['GroupId']
  ec2.authorize_security_group_ingress(
      GroupId=sg_pub_id,
      IpPermissions=[{
          'IpProtocol': 'tcp',
          'FromPort': 22,
          'ToPort': 22,
          'IpRanges': [{'CidrIp': '0.0.0.0/0', 'Description': 'SSH publico'}],
      }],
  )

  # SG 2: Privado (solo acepta SSH desde la instancia con SG Público)
  sg_priv = ec2.create_security_group(
      GroupName='SG-Privado-SSH',
      Description='Permitir trafico SSH solo desde la subred publica',
      VpcId=vpc_id,
  )
  sg_priv_id = sg_priv['GroupId']
  ec2.authorize_security_group_ingress(
      GroupId=sg_priv_id,
      IpPermissions=[{
          'IpProtocol': 'tcp',
          'FromPort': 22,
          'ToPort': 22,
          'UserIdGroupPairs': [{'GroupId': sg_pub_id}],
      }],
  )

  print(f'Security Groups creados: Público ({sg_pub_id}) y Privado ({sg_priv_id})')
  return sg_pub_id, sg_priv_id


# MODIFICADO: Se añade 'asignar_ip_publica' para forzar IP pública en NetworkInterfaces
def crear_instancia_ec2(ec2, subnet_id, sg_id, nombre, asignar_ip_publica=False):
  imagen_ami = 'ami-0c7217cdde317cfec'

  if asignar_ip_publica:
    response = ec2.run_instances(
        ImageId=imagen_ami,
        InstanceType='t3.micro',
        KeyName='vockey',
        MinCount=1,
        MaxCount=1,
        NetworkInterfaces=[{
            'SubnetId': subnet_id,
            'DeviceIndex': 0,
            'AssociatePublicIpAddress': True,
            'Groups': [sg_id],
        }],
        TagSpecifications=[{
            'ResourceType': 'instance',
            'Tags': [{'Key': 'Name', 'Value': nombre}],
        }],
    )
  else:
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
            'Tags': [{'Key': 'Name', 'Value': nombre}],
        }],
    )

  instancia_id = response['Instances'][0]['InstanceId']
  print(f'Instancia EC2 ({nombre}) creada con ID: {instancia_id}')
  return instancia_id


if __name__ == '__main__':
  ec2_client, vpc_id, rt_pub_id = crear_vpc()
  subnet_pub_id = crear_subred_publica(ec2_client, vpc_id, rt_pub_id)

  subnet_priv_id = crear_red_privada(ec2_client, vpc_id, subnet_pub_id)

  sg_pub_id, sg_priv_id = crear_security_groups(ec2_client, vpc_id)

  # Lanzar instancia en subred pública (hereda IP pública de la subred)
  inst_pub = crear_instancia_ec2(
      ec2_client, subnet_pub_id, sg_pub_id, 'Instancia-Publica'
  )
  # Lanzar instancia en subred privada forzando la asignación de IP pública
  inst_priv = crear_instancia_ec2(
      ec2_client,
      subnet_priv_id,
      sg_priv_id,
      'Instancia-Privada',
      asignar_ip_publica=True,
  )

  print('Despliegue finalizado con éxito.')
