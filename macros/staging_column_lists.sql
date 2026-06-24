{# =============================================================================
   staging_column_lists.sql

   Column-list macros used by the staging union models. Each column is cast
   to an explicit type so the UNION ALL across per-entity bronze tables
   doesn't fail when dbt's per-seed type inference produces inconsistent
   types (e.g. TEXT in one entity, INTEGER in another).

   When real BC data lands, the same casts apply unchanged — they coerce
   whatever the BC connector produces into the canonical staging type.
   ============================================================================= #}


{# gl_entry — BC Table 17. 23 BC columns + Company_Name. #}
{% macro gl_entry_column_list(company_name) -%}
    '{{ company_name }}'                                    as "Company_Name",
    cast("Entry_No"                  as bigint)             as "Entry_No",
    cast("Posting_Date"              as date)               as "Posting_Date",
    cast("Document_Type"             as text)               as "Document_Type",
    cast("Document_No"               as text)               as "Document_No",
    cast("External_Document_No"      as text)               as "External_Document_No",
    cast("Transaction_No"            as bigint)             as "Transaction_No",
    cast("G_L_Account_No"            as text)               as "G_L_Account_No",
    cast("Description"               as text)               as "Description",
    cast("Amount"                    as numeric(20, 4))     as "Amount",
    cast("Debit_Amount"              as numeric(20, 4))     as "Debit_Amount",
    cast("Credit_Amount"             as numeric(20, 4))     as "Credit_Amount",
    cast("Source_Code"               as text)               as "Source_Code",
    cast("Source_Type"               as text)               as "Source_Type",
    cast("Source_No"                 as text)               as "Source_No",
    cast("Dimension_Set_ID"          as bigint)             as "Dimension_Set_ID",
    cast("Global_Dimension_1_Code"   as text)               as "Global_Dimension_1_Code",
    cast("Global_Dimension_2_Code"   as text)               as "Global_Dimension_2_Code",
    cast("Business_Unit_Code"        as text)               as "Business_Unit_Code",
    cast("IC_Partner_Code"           as text)               as "IC_Partner_Code",
    cast("User_ID"                   as text)               as "User_ID",
    cast("Reversed"                  as text)               as "Reversed",
    cast(nullif(cast("Reversed_by_Entry_No" as text), '') as bigint) as "Reversed_by_Entry_No",
    cast(nullif(cast("Reversed_Entry_No"    as text), '') as bigint) as "Reversed_Entry_No"
{%- endmacro %}


{# gl_account — BC Table 15. 11 BC columns + Company_Name. #}
{% macro gl_account_column_list(company_name) -%}
    '{{ company_name }}'                                    as "Company_Name",
    cast("G_L_Account_No"            as text)               as "G_L_Account_No",
    cast("Name"                      as text)               as "Name",
    cast("Account_Type"              as text)               as "Account_Type",
    cast("Account_Category"          as text)               as "Account_Category",
    cast("Income_Balance"            as text)               as "Income_Balance",
    cast("Debit_Credit"              as text)               as "Debit_Credit",
    cast("Direct_Posting"            as text)               as "Direct_Posting",
    cast("Blocked"                   as text)               as "Blocked",
    cast(nullif(cast("Indentation" as text), '') as int)    as "Indentation",
    cast("Totaling"                  as text)               as "Totaling",
    cast("Consol_Translation_Method" as text)               as "Consol_Translation_Method"
{%- endmacro %}


{# dimension_set_entry — BC Table 480. 4 BC columns + Company_Name. #}
{% macro dimension_set_entry_column_list(company_name) -%}
    '{{ company_name }}'                                    as "Company_Name",
    cast("Dimension_Set_ID"          as bigint)             as "Dimension_Set_ID",
    cast("Dimension_Code"            as text)               as "Dimension_Code",
    cast("Dimension_Value_Code"      as text)               as "Dimension_Value_Code",
    cast("Dimension_Value_ID"        as bigint)             as "Dimension_Value_ID"
{%- endmacro %}


{# dimension_value — BC Table 349. 5 BC columns + Company_Name. #}
{% macro dimension_value_column_list(company_name) -%}
    '{{ company_name }}'                                    as "Company_Name",
    cast("Dimension_Code"            as text)               as "Dimension_Code",
    cast("Code"                      as text)               as "Code",
    cast("Name"                      as text)               as "Name",
    cast("Dimension_Value_Type"      as text)               as "Dimension_Value_Type",
    cast("Totaling"                  as text)               as "Totaling"
{%- endmacro %}
