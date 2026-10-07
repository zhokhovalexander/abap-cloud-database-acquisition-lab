CLASS zcl_db_source_init DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_source_init IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DELETE FROM zdb_src_price.

    DATA lt_source TYPE TABLE OF zdb_src_price.

    lt_source = VALUE #(
      ( product_id  = 'P1001'
        store_group = 'SOUTH'
        price       = '10.00'
        currency    = 'EUR'
        created_seq = 1001
        is_deleted  = '' )

      ( product_id  = 'P1002'
        store_group = 'SOUTH'
        price       = '20.00'
        currency    = 'EUR'
        created_seq = 1002
        is_deleted  = '' )

      ( product_id  = 'P1003'
        store_group = 'SOUTH'
        price       = '30.00'
        currency    = 'EUR'
        created_seq = 1003
        is_deleted  = '' )

      ( product_id  = 'P1001'
        store_group = 'NORTH'
        price       = '11.50'
        currency    = 'EUR'
        created_seq = 1004
        is_deleted  = '' )
    ).

    INSERT zdb_src_price FROM TABLE @lt_source.

    IF sy-subrc = 0.
      out->write( |Source initialized: { lines( lt_source ) } rows.| ).
    ELSE.
      out->write( |Initialization failed. SY-SUBRC = { sy-subrc }| ).
    ENDIF.

  ENDMETHOD.

ENDCLASS.
