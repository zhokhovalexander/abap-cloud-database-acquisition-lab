
CLASS zcl_db_source_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_source_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    "------------------------------------------------------------
    " 1. Insert a new source record
    "------------------------------------------------------------
    DATA(ls_new_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = 'P1004'
      store_group = 'SOUTH'
      price       = '40.00'
      currency    = 'EUR'
      created_seq = 1005
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_new_price.

    IF sy-subrc = 0.
      out->write( 'INSERT: P1004/SOUTH created with sequence 1005.' ).
    ELSE.
      out->write(
        |INSERT failed. SY-SUBRC = { sy-subrc }|
      ).
      RETURN.
    ENDIF.


    "------------------------------------------------------------
    " 2. Update an existing old record
    "    CREATED_SEQ intentionally remains unchanged
    "------------------------------------------------------------
    UPDATE zdb_src_price
      SET price = '12.00'
      WHERE product_id  = 'P1001'
        AND store_group = 'SOUTH'.

    IF sy-subrc = 0.
      out->write(
        'UPDATE: P1001/SOUTH price changed from 10.00 to 12.00.'
      ).
    ELSE.
      out->write(
        |UPDATE failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

  ENDMETHOD.

ENDCLASS.
