#!/bin/bash
set -e

AZ="us-east-1a"
AMI_ID="ami-0c7217cdde317cfec"
INSTANCE_TYPE="t3.micro"
KEY_NAME="vockey"

crear_vpc() {
    echo "=== 1. Creando VPC y tabla de enrutamiento pública ==="
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block "192.168.0.0/16" \
        --query 'Vpc.VpcId' \
        --output text)
    echo "VPC creada con ID: $VPC_ID"

    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

    aws ec2 create-tags \
        --resources "$VPC_ID" \
        --tags Key=Name,Value=MiVPC-Boto3 Key=tipo,Value=prueba

    # Internet Gateway (IGW)
    IGW_ID=$(aws ec2 create-internet-gateway \
        --query 'InternetGateway.InternetGatewayId' \
        --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value=MiIGW-Boto3
    echo "Internet Gateway creado y adjuntado: $IGW_ID"

    # Tabla de enrutamiento PÚBLICA (apunta al IGW)
    RT_PUB_ID=$(aws ec2 create-route-table \
        --vpc-id "$VPC_ID" \
        --query 'RouteTable.RouteTableId' \
        --output text)
    aws ec2 create-route \
        --route-table-id "$RT_PUB_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$IGW_ID" > /dev/null
    aws ec2 create-tags \
        --resources "$RT_PUB_ID" \
        --tags Key=Name,Value=TablaRuteo-Publica-Boto3
    echo "Tabla de enrutamiento pública creada: $RT_PUB_ID"
}

crear_subred_publica() {
    echo "=== 2. Creando subred pública ==="
    SUBNET_PUB_ID=$(aws ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block "192.168.1.0/24" \
        --availability-zone "$AZ" \
        --query 'Subnet.SubnetId' \
        --output text)

    aws ec2 create-tags \
        --resources "$SUBNET_PUB_ID" \
        --tags Key=Name,Value=Subred-Publica-Boto3

    aws ec2 associate-route-table --route-table-id "$RT_PUB_ID" --subnet-id "$SUBNET_PUB_ID" > /dev/null
    aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUB_ID" --map-public-ip-on-launch
    echo "Subred PÚBLICA creada y configurada: $SUBNET_PUB_ID"
}

crear_red_privada() {
    echo "=== 3. Creando NAT Gateway y red privada ==="
    # 1. IP Elástica para el NAT Gateway
    EIP_ALLOC_ID=$(aws ec2 allocate-address \
        --domain vpc \
        --query 'AllocationId' \
        --output text)

    # 2. NAT Gateway alojado en la SUBRED PÚBLICA
    NAT_GW_ID=$(aws ec2 create-nat-gateway \
        --subnet-id "$SUBNET_PUB_ID" \
        --allocation-id "$EIP_ALLOC_ID" \
        --query 'NatGateway.NatGatewayId' \
        --output text)
    aws ec2 create-tags --resources "$NAT_GW_ID" --tags Key=Name,Value=MiNAT-Boto3
    echo "Creando NAT Gateway $NAT_GW_ID... esperando disponibilidad (1-2 min)."

    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
    echo "NAT Gateway listo."

    # 3. Subred PRIVADA
    SUBNET_PRIV_ID=$(aws ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block "192.168.2.0/24" \
        --availability-zone "$AZ" \
        --query 'Subnet.SubnetId' \
        --output text)
    aws ec2 create-tags \
        --resources "$SUBNET_PRIV_ID" \
        --tags Key=Name,Value=Subred-Privada-Boto3

    # 4. Tabla de enrutamiento PRIVADA (apunta al NAT Gateway)
    RT_PRIV_ID=$(aws ec2 create-route-table \
        --vpc-id "$VPC_ID" \
        --query 'RouteTable.RouteTableId' \
        --output text)
    aws ec2 create-route \
        --route-table-id "$RT_PRIV_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$NAT_GW_ID" > /dev/null
    aws ec2 create-tags \
        --resources "$RT_PRIV_ID" \
        --tags Key=Name,Value=TablaRuteo-Privada-Boto3

    # 5. Asociar tabla privada a subred privada
    aws ec2 associate-route-table --route-table-id "$RT_PRIV_ID" --subnet-id "$SUBNET_PRIV_ID" > /dev/null
    echo "Subred PRIVADA creada y enrutada al NAT: $SUBNET_PRIV_ID"
}

crear_security_groups() {
    echo "=== 4. Creando Security Groups ==="
    # SG 1: Público (acepta SSH desde internet)
    SG_PUB_ID=$(aws ec2 create-security-group \
        --group-name "SG-Publico-SSH" \
        --description "Permitir trafico SSH desde el exterior" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_PUB_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "0.0.0.0/0" > /dev/null

    # SG 2: Privado (solo acepta SSH desde la instancia con SG Público)
    SG_PRIV_ID=$(aws ec2 create-security-group \
        --group-name "SG-Privado-SSH" \
        --description "Permitir trafico SSH solo desde la subred publica" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_PRIV_ID" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$SG_PUB_ID}]" > /dev/null

    echo "Security Groups creados: Público ($SG_PUB_ID) y Privado ($SG_PRIV_ID)"
}

crear_instancia_ec2() {
    local SUBNET_ID="$1"
    local SG_ID="$2"
    local NOMBRE="$3"
    local ASIGNAR_IP_PUBLICA="${4:-false}"

    if [ "$ASIGNAR_IP_PUBLICA" = "true" ]; then
        INSTANCIA_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --count 1 \
            --network-interfaces "[{\"SubnetId\":\"$SUBNET_ID\",\"DeviceIndex\":0,\"AssociatePublicIpAddress\":true,\"Groups\":[\"$SG_ID\"]}]" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NOMBRE}]" \
            --query 'Instances[0].InstanceId' \
            --output text)
    else
        INSTANCIA_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --subnet-id "$SUBNET_ID" \
            --security-group-ids "$SG_ID" \
            --key-name "$KEY_NAME" \
            --count 1 \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NOMBRE}]" \
            --query 'Instances[0].InstanceId' \
            --output text)
    fi

    echo "Instancia EC2 ($NOMBRE) creada con ID: $INSTANCIA_ID"
}

# --- Ejecución principal ---
crear_vpc
crear_subred_publica
crear_red_privada
crear_security_groups

# Lanzar instancia en subred pública (hereda IP pública de la subred)
crear_instancia_ec2 "$SUBNET_PUB_ID" "$SG_PUB_ID" "Instancia-Publica" "false"

# Lanzar instancia en subred privada forzando la asignación de IP pública
crear_instancia_ec2 "$SUBNET_PRIV_ID" "$SG_PRIV_ID" "Instancia-Privada" "true"

echo "Despliegue finalizado con éxito."