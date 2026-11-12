#!/bin/bash

# Obtén los IDs de las VPCs que tienen la etiqueta tipo=prueba
VPC_IDS=$(aws ec2 describe-vpcs \
    --filters "Name=tag:tipo,Values=prueba" \
    --query "Vpcs[*].VpcId" \
    --output text)

# Si no se encuentra ninguna VPC con esa etiqueta, avisa y termina
if [ -z "$VPC_IDS" ] || [ "$VPC_IDS" = "None" ]; then
    echo "No se han encontrado VPCs con la etiqueta tipo=prueba."
    exit 0
fi

# Recorre cada ID de VPC encontrada y elimínala
for VPC_ID in $VPC_IDS; do
    echo "=========================================================="
    echo "Iniciando desmantelamiento TOTAL e INDEPENDIENTE para VPC: $VPC_ID"
    echo "=========================================================="
    
    # 1. ELIMINAR INSTANCIAS EC2
    INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped" --query "Reservations[*].Instances[*].InstanceId" --output text)
    if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "   -> Terminando instancias EC2 remanentes ($INSTANCE_IDS)..."
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS > /dev/null
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
    fi

    # 2. ELIMINAR ENDPOINTS DE INSTANCE CONNECT
    EICE_IDS=$(aws ec2 describe-instance-connect-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "InstanceConnectEndpoints[*].InstanceConnectEndpointId" --output text 2>/dev/null)
    for EICE_ID in $EICE_IDS; do
        if [ -n "$EICE_ID" ] && [ "$EICE_ID" != "None" ]; then
            echo "   -> Eliminando Endpoint EICE rezagado: $EICE_ID..."
            aws ec2 delete-instance-connect-endpoint --instance-connect-endpoint-id $EICE_ID > /dev/null 2>&1
            sleep 5
        fi
    done

    # 3. ELIMINAR INTERFACES DE RED (ENIs) SUELTAS
    ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text)
    for ENI in $ENIS; do
        if [ -n "$ENI" ] && [ "$ENI" != "None" ]; then
            echo "   -> Forzando la eliminacion de ENI suelta: $ENI..."
            aws ec2 delete-network-interface --network-interface-id $ENI > /dev/null 2>&1
        fi
    done

    # 4. ELIMINAR TABLAS DE ENRUTAMIENTO PERSONALIZADAS
    RTB_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations.Main!=\`true\`].RouteTableId" --output text)
    for RTB_ID in $RTB_IDS; do
        if [ -n "$RTB_ID" ] && [ "$RTB_ID" != "None" ]; then
            ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids $RTB_ID --query "RouteTables[*].Associations[*].RouteTableAssociationId" --output text)
            for ASSOC_ID in $ASSOC_IDS; do
                if [ -n "$ASSOC_ID" ] && [ "$ASSOC_ID" != "None" ]; then
                    echo "   -> Rompiendo asociacion de tabla: $ASSOC_ID..."
                    aws ec2 disassociate-route-table --association-id $ASSOC_ID > /dev/null 2>&1
                fi
            done
            echo "   -> Eliminando Tabla de Enrutamiento personalizada: $RTB_ID..."
            aws ec2 delete-route-table --route-table-id $RTB_ID > /dev/null 2>&1
        fi
    done

    # 5. ELIMINAR LAS SUBREDES
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)
    for SUBNET_ID in $SUBNET_IDS; do
        if [ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "None" ]; then
            echo "   -> Eliminando subred residual: $SUBNET_ID..."
            aws ec2 delete-subnet --subnet-id $SUBNET_ID > /dev/null 2>&1
        fi
    done

    # 6. DESACOPLAR Y ELIMINAR EL INTERNET GATEWAY
    IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[*].InternetGatewayId" --output text)
    for IGW_ID in $IGW_IDS; do
        if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
            echo "   -> Desacoplando Internet Gateway de la VPC..."
            aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID > /dev/null 2>&1
            sleep 2
            echo "   -> Eliminando Internet Gateway huerfano: $IGW_ID..."
            aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID > /dev/null 2>&1
        fi
    done

    # 7. ELIMINAR SECURITY GROUPS PERSONALIZADOS
    SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
    for SG_ID in $SG_IDS; do
        if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
            echo "   -> Eliminando Security Group residual: $SG_ID..."
            aws ec2 delete-security-group --group-id $SG_ID > /dev/null 2>&1
        fi
    done
    
    # 8. ELIMINAR LA VPC FINAL
    echo "   -> Intentando el borrado final de la VPC completamente limpia..."
    sleep 2
    aws ec2 delete-vpc --vpc-id $VPC_ID
    echo "VPC $VPC_ID eliminada por completo del mapa."
done