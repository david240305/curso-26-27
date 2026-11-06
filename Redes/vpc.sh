#!/bin/bash

echo "=== 1. Creando VPC y configuraciones de red ==="
VPC_ID=$(aws ec2 create-vpc --cidr-block 193.168.5.0/16 --query 'Vpc.VpcId' --output text)
echo "VPC creada con ID: $VPC_ID"

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=MiVPC-Boto3

# Crear e Internet Gateway (IGW)
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value=MiIGW-Boto3
echo "Internet Gateway creado y adjuntado: $IGW_ID"

# Crear Tabla de enrutamiento y apuntarla al IGW
ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
aws ec2 create-tags --resources "$ROUTE_TABLE_ID" --tags Key=Name,Value=MiTablaRuteo-Boto3
echo "Tabla de enrutamiento configurada hacia el IGW: $ROUTE_TABLE_ID"

echo "=== 2. Creando Subred y asociándola ==="
SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 193.168.5.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
echo "Subred creada con ID: $SUBNET_ID"

aws ec2 create-tags --resources "$SUBNET_ID" --tags Key=Name,Value=MiSubred-Boto3
aws ec2 associate-route-table --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_ID" > /dev/null
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
echo "Tabla de enrutamiento asociada a la subred $SUBNET_ID y auto-asignación de IP pública activada."

echo "=== 3. Creando Security Group (Puerto 22) ==="
SG_ID=$(aws ec2 create-security-group --group-name "SG-Acceso-SSH" --description "Permitir trafico SSH desde el exterior" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null
echo "Security Group creado con ID: $SG_ID (Puerto 22 abierto)"

echo "=== 4. Lanzando Instancia EC2 ==="
IMAGEN_AMI="ami-0c7217cdde317cfec"
INSTANCIA_ID=$(aws ec2 run-instances \
    --image-id "$IMAGEN_AMI" \
    --instance-type t3.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --count 1 \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=MiInstancia-Boto3}]' \
    --query 'Instances[0].InstanceId' --output text)

echo "Instancia EC2 creada con ID: $INSTANCIA_ID"
echo "Despliegue finalizado. Instancia $INSTANCIA_ID en subred $SUBNET_ID."