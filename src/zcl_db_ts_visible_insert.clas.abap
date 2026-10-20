CLASS zcl_db_ts_visible_insert DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_visible_insert IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_product_id  TYPE zdb_src_price-product_id
        VALUE 'P1008',
      c_store_group TYPE zdb_src_price-store_group
        VALUE 'SOUTH',
      c_price       TYPE zdb_src_price-price
        VALUE '80.00',
      c_currency    TYPE zdb_src_price-currency
        VALUE 'EUR',
      c_created_seq TYPE zdb_src_price-created_seq
        VALUE 1009.

    DATA(lv_change_at) = utclong_current( ).

    "------------------------------------------------------------
    " Visible INSERT for the delayed-COMMIT experiment.
    "
    " This row is committed immediately in a second session.
    " Its CHANGED_AT is later than the timestamp of the pending
    " uncommitted UPDATE created by ZCL_DB_TS_DELAYED_UPDATE.
    "
    " With the naive timestamp reader this can advance the
    " delta pointer beyond the still-uncommitted older change.
    "------------------------------------------------------------
    DATA(ls_new_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = c_product_id
      store_group = c_store_group
      price       = c_price
      currency    = c_currency

      " Current-state creation sequence; not used by timestamp delta.
      created_seq = c_created_seq

      changed_at  = lv_change_at
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_new_price.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |INSERT failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Visible INSERT committed: { c_product_id }/{ c_store_group }, |
      && |CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
