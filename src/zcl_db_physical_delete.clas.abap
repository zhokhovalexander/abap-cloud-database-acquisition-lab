CLASS zcl_db_physical_delete DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_physical_delete IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

  CONSTANTS:
      c_product_id  TYPE zdb_src_price-product_id
        VALUE 'P1003',
      c_store_group TYPE zdb_src_price-store_group
        VALUE 'SOUTH'.

    "------------------------------------------------------------
    " Physical DELETE experiment.
    "
    " The row is removed completely from the current-state table.
    " A timestamp-based delta can no longer detect this change
    " because no source row remains to be selected.
    "------------------------------------------------------------

    DELETE FROM zdb_src_price
      WHERE product_id  = @c_product_id
        AND store_group = @c_store_group.

    IF sy-subrc <> 0.
      out->write(
        |DELETE failed or row not found. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
        |DELETE failed or row not found. SY-SUBRC = { sy-subrc }|
      ).

  ENDMETHOD.

ENDCLASS.
