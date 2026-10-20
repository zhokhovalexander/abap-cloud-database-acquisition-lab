CLASS zcl_db_ts_source_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_source_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_update_product TYPE zdb_src_price-product_id
        VALUE 'P1001',
      c_insert_product TYPE zdb_src_price-product_id
        VALUE 'P1005',
      c_store_group    TYPE zdb_src_price-store_group
        VALUE 'SOUTH',
      c_update_price   TYPE zdb_src_price-price
        VALUE '13.00',
      c_insert_price   TYPE zdb_src_price-price
        VALUE '50.00',
      c_currency       TYPE zdb_src_price-currency
        VALUE 'EUR',
      c_created_seq    TYPE zdb_src_price-created_seq
        VALUE 1006.

    DATA(lv_change_at) = utclong_current( ).

    "------------------------------------------------------------
    " Prepare the timestamp-delta experiment.
    "
    " Both changes intentionally receive the same CHANGED_AT.
    "
    " - The UPDATE keeps its old CREATED_SEQ.
    " - The INSERT receives a new CREATED_SEQ.
    "
    " Timestamp delta should detect both rows because it uses
    " CHANGED_AT rather than CREATED_SEQ.
    "------------------------------------------------------------


    "------------------------------------------------------------
    " 1. Update an existing old record
    "------------------------------------------------------------
    UPDATE zdb_src_price
      SET price      = @c_update_price,
          changed_at = @lv_change_at
      WHERE product_id  = @c_update_product
        AND store_group = @c_store_group.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |UPDATE failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.


    "------------------------------------------------------------
    " 2. Insert a new source record
    "------------------------------------------------------------
    DATA(ls_new_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = c_insert_product
      store_group = c_store_group
      price       = c_insert_price
      currency    = c_currency
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


    "------------------------------------------------------------
    " 3. Commit both source changes together
    "------------------------------------------------------------
    COMMIT WORK.

    out->write(
      |UPDATE: { c_update_product }/{ c_store_group } -> { c_update_price }, |
      && |CHANGED_AT = { lv_change_at }|
    ).

    out->write(
      |INSERT: { c_insert_product }/{ c_store_group }, |
      && |CREATED_SEQ = { c_created_seq }, CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
