{#
  Land models in the schema they name, not target.schema + "_" + name.

  dbt's default concatenates: with target.schema = RAW and +schema: MART, models
  would be created in RAW_MART. That default exists so several developers can
  share a warehouse without colliding, which is not the situation here -- the
  layer names are the architecture, and MART must be MART.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
