#!/bin/bash

# DISCLAIMER:
# The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided “AS IS” and “WITH ALL FAULTS.” Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.
#
# The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.


function get_throughput_details_nosql() {
    # --- Account-level Throughput (if any, rarely applies for SQL API) ---3
    account_info=$(az cosmosdb show \
    --name $COSMOS_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query "{Account:name,Kind:kind}" -o tsv)

    if [[ -n "$account_info" ]]; then
    echo "$COSMOS_ACCOUNT,,,(Account Info),," >> $OUTPUT_FILE
    fi

    # --- Database-level Throughput ---
    for db in $(az cosmosdb sql database list \
        --account-name $COSMOS_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query "[].name" -o tsv); do

        throughput=$(az cosmosdb sql database throughput show \
            --account-name $COSMOS_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --name $db \
            --query "resource.throughput" -o tsv 2>/dev/null)

        autoscale=$(az cosmosdb sql database throughput show \
            --account-name $COSMOS_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --name $db \
            --query "resource.autoscaleSettings.maxThroughput" -o tsv 2>/dev/null)

        if [[ -n "$throughput" ]]; then
            echo "$COSMOS_ACCOUNT,$db,,Manual,$throughput" >> $OUTPUT_FILE
        elif [[ -n "$autoscale" ]]; then
            echo "$COSMOS_ACCOUNT,$db,,Autoscale,$autoscale" >> $OUTPUT_FILE
        else
            echo "$COSMOS_ACCOUNT,$db,,Inherited," >> $OUTPUT_FILE
        fi
    done

    # --- Container-level Throughput ---
    for db in $(az cosmosdb sql database list \
        --account-name $COSMOS_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query "[].name" -o tsv); do

        for container in $(az cosmosdb sql container list \
            --account-name $COSMOS_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --database-name $db \
            --query "[].name" -o tsv); do

            throughput=$(az cosmosdb sql container throughput show \
                --account-name $COSMOS_ACCOUNT \
                --resource-group $RESOURCE_GROUP \
                --database-name $db \
                --name $container \
                --query "resource.throughput" -o tsv 2>/dev/null)

            autoscale=$(az cosmosdb sql container throughput show \
                --account-name $COSMOS_ACCOUNT \
                --resource-group $RESOURCE_GROUP \
                --database-name $db \
                --name $container \
                --query "resource.autoscaleSettings.maxThroughput" -o tsv 2>/dev/null)

            if [[ -n "$throughput" ]]; then
                echo "$COSMOS_ACCOUNT,$db,$container,Manual,$throughput" >> $OUTPUT_FILE
            elif [[ -n "$autoscale" ]]; then
                echo "$COSMOS_ACCOUNT,$db,$container,Autoscale,$autoscale" >> $OUTPUT_FILE
            else
                echo "$COSMOS_ACCOUNT,$db,$container,Inherited," >> $OUTPUT_FILE
            fi
        done
    done
}

function get_throughput_details_mongo() {
    # --- Account-level Throughput (if any, rarely applies for SQL API) ---3
    account_info=$(az cosmosdb show \
    --name $COSMOS_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query "{Account:name,Kind:kind}" -o tsv)

    if [[ -n "$account_info" ]]; then
    echo "$COSMOS_ACCOUNT,,,(Account Info),," >> $OUTPUT_FILE
    fi

    # --- Database-level Throughput ---
    for db in $(az cosmosdb mongodb database list \
        --account-name $COSMOS_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query "[].name" -o tsv); do

        throughput=$(az cosmosdb mongodb database throughput show \
            --account-name $COSMOS_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --name $db \
            --query "resource.throughput" -o tsv 2>/dev/null)

        autoscale=$(az cosmosdb mongodb database throughput show \
            --account-name $COSMOS_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --name $db \
            --query "resource.autoscaleSettings.maxThroughput" -o tsv 2>/dev/null)

        if [[ -n "$throughput" ]]; then
            echo "$COSMOS_ACCOUNT,$db,,Manual,$throughput" >> $OUTPUT_FILE
        elif [[ -n "$autoscale" ]]; then
            echo "$COSMOS_ACCOUNT,$db,,Autoscale,$autoscale" >> $OUTPUT_FILE
        else
            echo "$COSMOS_ACCOUNT,$db,,Inherited," >> $OUTPUT_FILE
        fi
    done

    # --- Container-level Throughput ---
    for db in $(az cosmosdb mongodb database list \
        --account-name $COSMOS_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query "[].name" -o tsv); do

        for container in $(az cosmosdb mongodb collection list \
            --account-name $COSMOS_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --database-name $db \
            --query "[].name" -o tsv); do

            throughput=$(az cosmosdb mongodb collection throughput show \
                --account-name $COSMOS_ACCOUNT \
                --resource-group $RESOURCE_GROUP \
                --database-name $db \
                --name $container \
                --query "resource.throughput" -o tsv 2>/dev/null)

            autoscale=$(az cosmosdb mongodb collection throughput show \
                --account-name $COSMOS_ACCOUNT \
                --resource-group $RESOURCE_GROUP \
                --database-name $db \
                --name $container \
                --query "resource.autoscaleSettings.maxThroughput" -o tsv 2>/dev/null)

            if [[ -n "$throughput" ]]; then
                echo "$COSMOS_ACCOUNT,$db,$container,Manual,$throughput" >> $OUTPUT_FILE
            elif [[ -n "$autoscale" ]]; then
                echo "$COSMOS_ACCOUNT,$db,$container,Autoscale,$autoscale" >> $OUTPUT_FILE
            else
                echo "$COSMOS_ACCOUNT,$db,$container,Inherited," >> $OUTPUT_FILE
            fi
        done
    done
}


# COSMOS_ACCOUNT="athleteorder-cosmos-dev"
# RESOURCE_GROUP="customer-order-nonprod"
OUTPUT_FILE="cosmos_ru_report.csv"

echo "Account,Database,Container,Throughput_Type,Throughput_RU" > $OUTPUT_FILE

for sub in $(az account list --query "[].id" -o tsv); do
    echo "Processing Subscription: $sub"
    az account set --subscription $sub
    dbaccounts=$(az cosmosdb list --query "[].{name:name, resourceGroup:resourceGroup, kind:kind}" -o tsv)
    if [[ -z "$dbaccounts" ]]; then
        echo "  No Cosmos DB accounts found in this subscription."
    else
        while IFS=$'\t' read -r COSMOS_ACCOUNT RESOURCE_GROUP KIND; do
            echo "  Processing Cosmos DB Account: $COSMOS_ACCOUNT in Resource Group: $RESOURCE_GROUP"
            # Call the function to get throughput details
            if [[ "$KIND" == "GlobalDocumentDB" ]]; then
                get_throughput_details_nosql $COSMOS_ACCOUNT $RESOURCE_GROUP
            elif [[ "$KIND" == "MongoDB" ]]; then
                get_throughput_details_mongo $COSMOS_ACCOUNT $RESOURCE_GROUP
            fi
        done <<< "$dbaccounts"
    fi
done