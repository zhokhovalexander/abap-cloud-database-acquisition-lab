CLASS zcl_db_soft_delete_prep DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_soft_delete_prep IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

   CONSTANTS:
      c_product_id  TYPE zdb_src_price-product_id
        VALUE 'P1003',
      c_store_group TYPE zdb_src_price-store_group
        VALUE 'SOUTH',
      c_price       TYPE zdb_src_price-price
        VALUE '30.00',
      c_currency    TYPE zdb_src_price-currency
        VALUE 'EUR',
      c_created_seq TYPE zdb_src_price-created_seq
        VALUE 1010.

    DATA(lv_change_at) = utclong_current( ).

    "------------------------------------------------------------
    " Prepare the soft-delete experiment.
    "
    " P1003/SOUTH is expected to be absent after the physical
    " DELETE experiment. This class restores it as an active row
    " so that ZCL_DB_SOFT_DELETE can subsequently mark it as
    " logically deleted.
    "------------------------------------------------------------

    DATA(ls_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = c_product_id
      store_group = c_store_group
      price       = c_price
      currency    = c_currency
      created_seq = c_created_seq
      changed_at  = lv_change_at
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_price.

    IF sy-subrc <> 0.
      out->write(
        |Restore failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |{ c_product_id }/{ c_store_group } restored. |
      && |CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
